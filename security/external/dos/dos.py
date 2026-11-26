#!/usr/bin/env python3
"""Application denial-of-service aggregator of the external attack campaigns.

    security/external/dos/dos.py --artifacts report/ [--expected expected.json]

The attack itself runs from the disposable source machine, NOT from a GitHub runner (k6 burst,
slowhttptest, resource-exhaustion probes; run.sh). During each scenario the Argo CD machine captures
kubectl snapshots (get pods -o json, top pods). This aggregator reads every scenario's artifacts and
checks the acceptance criteria of the rules of engagement (docs/en/external-attack-campaigns.md):

- the service sheds load with 429 / 413, not 5xx or timeouts;
- no pod restarted (restartCount unchanged between the before/after snapshots);
- every pod stays under its memory limit;
- the legitimate agent's p95 latency stays under the frame's threshold;
- the instance recovers on its own within the frame's time.

Each threshold not met is a finding; the run exits 1 on any finding. Per scenario, in
<artifacts>/<scenario>/: attack-summary.json and legit-summary.json (k6 --summary-export), pods-before.json
and pods-after.json (kubectl get pods -o json), top-after.txt (kubectl top pods --no-headers) and
recovery.json ({"recovered_after_seconds": N | null}). A missing file only skips its own check.
Standard library only.
"""

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
UNIT = {"Ki": 1024, "Mi": 1024 ** 2, "Gi": 1024 ** 3, "Ti": 1024 ** 4,
        "K": 1000, "M": 1000 ** 2, "G": 1000 ** 3, "T": 1000 ** 4}


def to_bytes(value):
    """Kubernetes memory quantity → bytes ("512Mi", "1Gi", "268435456", "350m" rejected)."""
    if value in (None, ""):
        return None
    match = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([KMGT]i?)?", str(value).strip())
    if not match:
        return None
    number, unit = match.group(1), match.group(2)
    return int(float(number) * (UNIT.get(unit, 1)))


def finding(scenario, severity, title, detail=""):
    return {"scenario": scenario, "severity": severity, "title": title, "detail": detail}


# --------------------------------------------------------------------------- k6

def k6_metric(summary, name, key):
    try:
        return summary["metrics"][name]["values"][key]
    except (KeyError, TypeError):
        return None


def attack_findings(scenario, summary, thr):
    """The attack must be shed with 429/413, not 5xx or timeouts."""
    out = []
    counts = {code: (k6_metric(summary, f"status_{code}", "count") or 0)
              for code in ("2xx", "429", "413", "5xx", "timeout")}
    total = sum(counts.values())
    if total == 0:
        return [finding(scenario, "low", "attack sent no measured response (check the run)")]
    shed = counts["429"] + counts["413"]
    broke = counts["5xx"] + counts["timeout"]
    if broke / total > thr["max_error_fraction"]:
        out.append(finding(scenario, "high",
                           f"the service broke under load: {broke}/{total} responses were 5xx or "
                           f"timeouts (> {thr['max_error_fraction']:.0%}), not 429/413"))
    elif shed == 0:
        out.append(finding(scenario, "medium",
                           "no 429/413 under load: no rate or body-size limit shed the attack"))
    return out, counts


def legit_findings(scenario, summary, thr):
    """The legitimate agent's p95 latency must stay under the frame's threshold."""
    p95 = k6_metric(summary, "http_req_duration", "p(95)")
    if p95 is None:
        return []
    if p95 > thr["legit_p95_ms"]:
        return [finding(scenario, "high",
                        f"the legitimate agent's p95 latency was {p95:.0f} ms during the attack "
                        f"(> {thr['legit_p95_ms']} ms)")]
    return []


# --------------------------------------------------------------------------- kubectl

def restarts(pods):
    out = {}
    for pod in pods.get("items", []):
        name = pod["metadata"]["name"]
        for cs in pod.get("status", {}).get("containerStatuses", []):
            out[f"{name}/{cs['name']}"] = cs.get("restartCount", 0)
    return out


def restart_findings(scenario, before, after):
    out, b = [], restarts(before)
    for key, count in restarts(after).items():
        if count > b.get(key, count):
            out.append(finding(scenario, "high",
                               f"pod container {key} restarted during the attack "
                               f"({b.get(key, '?')} → {count})"))
    return out


def memory_limits(pods):
    out = {}
    for pod in pods.get("items", []):
        name = pod["metadata"]["name"]
        for c in pod.get("spec", {}).get("containers", []):
            limit = c.get("resources", {}).get("limits", {}).get("memory")
            out[name] = to_bytes(limit)  # by pod; one container per app pod here
    return out


def parse_top(text):
    """`kubectl top pods --no-headers` → {pod: memory_bytes}."""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            out[parts[0]] = to_bytes(parts[2])
    return out


def memory_findings(scenario, pods_after, top_text, thr):
    out = []
    limits, usage = memory_limits(pods_after), parse_top(top_text)
    for pod, used in usage.items():
        limit = limits.get(pod)
        if used is None or limit is None:
            continue
        if used >= limit * thr["memory_fraction"]:
            out.append(finding(scenario, "high",
                               f"pod {pod} reached {used // 1024**2} Mi, at or over "
                               f"{thr['memory_fraction']:.0%} of its {limit // 1024**2} Mi limit"))
    return out


def recovery_findings(scenario, recovery, thr):
    seconds = recovery.get("recovered_after_seconds")
    if seconds is None:
        return [finding(scenario, "high", "the instance did not recover on its own within the window")]
    if seconds > thr["recovery_max_seconds"]:
        return [finding(scenario, "medium",
                        f"slow self-recovery: {seconds} s (> {thr['recovery_max_seconds']} s)")]
    return []


# --------------------------------------------------------------------------- run

def _load(path):
    return json.loads(path.read_text()) if path.is_file() else None


def evaluate_scenario(scenario, bundle, thr):
    """bundle: dict of the parsed artifacts (None when a file is absent). → (findings, observations)."""
    out, obs = [], {}
    if bundle.get("attack") is not None:
        result = attack_findings(scenario, bundle["attack"], thr)
        attack, obs["attack_counts"] = (result if isinstance(result, tuple) else (result, {}))
        out += attack
    if bundle.get("legit") is not None:
        out += legit_findings(scenario, bundle["legit"], thr)
        obs["legit_p95_ms"] = k6_metric(bundle["legit"], "http_req_duration", "p(95)")
    if bundle.get("pods_before") is not None and bundle.get("pods_after") is not None:
        out += restart_findings(scenario, bundle["pods_before"], bundle["pods_after"])
    if bundle.get("pods_after") is not None and bundle.get("top") is not None:
        out += memory_findings(scenario, bundle["pods_after"], bundle["top"], thr)
    if bundle.get("recovery") is not None:
        out += recovery_findings(scenario, bundle["recovery"], thr)
        obs["recovered_after_seconds"] = bundle["recovery"].get("recovered_after_seconds")
    return out, obs


def load_bundle(scenario_dir):
    return {
        "attack": _load(scenario_dir / "attack-summary.json"),
        "legit": _load(scenario_dir / "legit-summary.json"),
        "pods_before": _load(scenario_dir / "pods-before.json"),
        "pods_after": _load(scenario_dir / "pods-after.json"),
        "top": (scenario_dir / "top-after.txt").read_text() if (scenario_dir / "top-after.txt").is_file() else None,
        "recovery": _load(scenario_dir / "recovery.json"),
    }


def render_markdown(report):
    lines = [f"# External attack campaign — application denial of service, {report['date']}", "",
             f"Target: `{report['domain']}`.", ""]
    status = "FAILED" if report["deviations"] else "OK"
    lines += [f"**{status}**: {len(report['deviations'])} finding(s).", "", "## Findings", ""]
    for d in report["deviations"]:
        lines.append(f"- **{d['severity'].upper()}** [{d['scenario']}] {d['title']}")
    if not report["deviations"]:
        lines.append("- none")
    lines += ["", "## Scenarios", ""]
    for name, res in report["scenarios"].items():
        lines.append(f"- **{name}**: {'FAILED' if res['findings'] else 'ok'}")
    lines.append("")
    return "\n".join(lines)


def main(argv=None):
    import datetime

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--expected", default=str(HERE / "expected.json"))
    parser.add_argument("--artifacts", required=True, help="directory with one subdir per scenario")
    args = parser.parse_args(argv)

    cfg = json.loads(Path(args.expected).read_text())
    thr = cfg["thresholds"]
    artifacts = Path(args.artifacts)
    report = {"domain": cfg["domain"], "scenarios": {}, "deviations": []}
    for name in cfg["scenarios"]:
        scenario_dir = artifacts / name
        if not scenario_dir.is_dir():
            report["scenarios"][name] = {"findings": [finding(name, "low", "no artifacts for this scenario")],
                                         "observations": {}}
            report["deviations"] += report["scenarios"][name]["findings"]
            continue
        findings, obs = evaluate_scenario(name, load_bundle(scenario_dir), thr)
        report["scenarios"][name] = {"findings": findings, "observations": obs}
        report["deviations"] += findings

    report["date"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    artifacts.mkdir(parents=True, exist_ok=True)
    (artifacts / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (artifacts / "report.md").write_text(render_markdown(report) + "\n")
    print(render_markdown(report))
    return 1 if report["deviations"] else 0


if __name__ == "__main__":
    sys.exit(main())
