#!/usr/bin/env python3
"""Single entry point of an external attack campaign.

    AUTH_TEST_PASSWORD=... security/external/campaign.py --out-dir campaign/ [--skip dos] [--aggregate-only]

Chains the scenario families in the order of the rules of engagement
(docs/en/external-attack-campaigns.md) — reconnaissance, authentication, access control, active
scan, business logic, supply chain, then application denial of service LAST — and folds each
family's report into one `campaign-report.md`: a section per family (what ran, result against its
success criterion, where the evidence is) and the state of controls E-01…E-13.

Two kinds of family (expected.json):

- `driver`: a standard-library scenario this entry point runs itself (recon, auth, access, business).
  With `--aggregate-only` it reads an existing report instead of running it.
- `manual`: a family run by hand in a window (the active DAST and the DoS, which runs from the source
  machine) or enforced elsewhere (the supply-chain guards, enforced in mairie360/CICD). This entry
  point does not run it; it reads its report from `<out-dir>/<family>/` if the operator produced one,
  else records it as not run this campaign.

Exit 1 if any family that ran reports a finding, or if a family that the campaign requires did not
run. The report is attached to the campaign's ticket. Standard library only.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_report(path):
    return json.loads(path.read_text()) if path.is_file() else None


def family_verdict(family, report):
    """(status, count, detail) for one family from its report.
    status: ok | failed | not_run."""
    if report is None:
        return "not_run", 0, "no report for this campaign"
    key = family["result_key"]
    findings = report.get(key, [])
    # The DAST report carries a boolean `failed` on top of its findings list.
    failed = report.get("failed", False) or bool(findings)
    return ("failed" if failed else "ok"), len(findings), f"{len(findings)} finding(s)"


def run_driver(family, out_dir, env_ok, aggregate_only, runner):
    """Run a driver family (unless --aggregate-only), then return its report."""
    report_dir = out_dir / family["key"]
    if not aggregate_only:
        if family.get("needs_password") and not env_ok:
            # Cannot run without the test-account password; fall back to an existing report.
            pass
        else:
            runner(family, report_dir)
    return load_report(report_dir / family["report_file"])


def default_runner(family, report_dir):
    report_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(HERE / family["command"]), "--out-dir", str(report_dir)],
                   check=False)


def run(cfg, out_dir, skip, aggregate_only, runner=default_runner, env_ok=True):
    report = {"families": [], "deviations": 0, "missing_required": []}
    for family in cfg["families"]:
        if family["key"] in skip:
            report["families"].append({**_meta(family), "status": "skipped", "count": 0})
            continue
        if family["mode"] == "driver":
            data = run_driver(family, out_dir, env_ok, aggregate_only, runner)
        else:
            data = load_report(out_dir / family["key"] / family["report_file"])
        status, count, detail = family_verdict(family, data)
        report["families"].append({**_meta(family), "status": status, "count": count, "detail": detail})
        if status == "failed":
            report["deviations"] += count
        if status == "not_run" and family.get("required"):
            report["missing_required"].append(family["key"])
    return report


def _meta(family):
    return {"key": family["key"], "label": family["label"], "criterion": family["criterion"],
            "mode": family["mode"], "controls": family.get("controls", [])}


def render_markdown(cfg, report):
    lines = [f"# External attack campaign — {report['date']}", "",
             f"Target: `{cfg['target']}`. Order of families: reconnaissance → authentication → access "
             "control → active scan → business logic → supply chain → denial of service.", ""]
    failed = report["deviations"] > 0 or report["missing_required"]
    lines += [f"**{'FAILED' if failed else 'OK'}**: {report['deviations']} finding(s) across the "
              f"families.", ""]
    if report["missing_required"]:
        lines.append(f"Required families that did not run: {', '.join(report['missing_required'])}.")
        lines.append("")
    lines += ["## Families", ""]
    for fam in report["families"]:
        badge = {"ok": "OK", "failed": "FAILED", "not_run": "not run", "skipped": "skipped"}[fam["status"]]
        lines += [f"### {fam['label']} — {badge}",
                  f"- Success criterion: {fam['criterion']}",
                  f"- Run: {fam['mode']}; {fam.get('detail', '')}",
                  f"- Report: `{cfg['out_dir_name']}/{fam['key']}/`",
                  f"- Controls: {', '.join(fam['controls']) or '—'}", ""]
    lines += ["## Controls E-01 → E-13", "", "| Control | Item | State | Ticket |", "| --- | --- | --- | --- |"]
    for control in cfg["controls"]:
        lines.append(f"| {control['id']} | {control['control']} | {control['state']} | {control['ticket']} |")
    lines += ["", "## Next dates", "",
              f"- Next full campaign: {cfg['schedule']['next_campaign']} (every quarter and before any "
              "major release).",
              f"- Next monthly reconnaissance: {cfg['schedule']['next_recon']} (first Monday, n8n).",
              "- Denial of service: in the campaign window only, launched by hand from the source machine.",
              ""]
    return "\n".join(lines)


def main(argv=None):
    import datetime
    import os

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--expected", default=str(HERE / "campaign.json"))
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--skip", default="", help="comma-separated family keys")
    parser.add_argument("--aggregate-only", action="store_true",
                        help="do not run the driver families, only read existing reports")
    args = parser.parse_args(argv)
    skip = {s for s in args.skip.split(",") if s}

    cfg = json.loads(Path(args.expected).read_text())
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    cfg["out_dir_name"] = out_dir.name
    report = run(cfg, out_dir, skip, args.aggregate_only, env_ok=bool(os.environ.get("AUTH_TEST_PASSWORD")))
    report["date"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    (out_dir / "campaign-report.json").write_text(json.dumps(report, indent=2) + "\n")
    (out_dir / "campaign-report.md").write_text(render_markdown(cfg, report) + "\n")
    print(render_markdown(cfg, report))
    return 1 if (report["deviations"] > 0 or report["missing_required"]) else 0


if __name__ == "__main__":
    sys.exit(main())
