#!/usr/bin/env python3
"""Business-logic and no-session abuse scenarios of the external attack campaigns.

    AUTH_TEST_PASSWORD=... security/external/business/business.py --out-dir report/ [--skip email]

Replays, against the staging front origins, the logic flaws scanners miss, plus the abuses that
need no session. Run by hand in an announced window (the e-mail block triggers real Resend sends).
Data-driven from expected.json, so a new case is a declaration, not code:

- sequences: a per-module journey where each step carries its expected outcome ("allow" / "refuse").
  A skipped step or a replayed action must be refused server-side, an action on a deleted or
  archived item must fail (404/403) — the front being bypassed does not matter.
- email abuse (no session): a bounded forgot-password loop, on one account and sprayed over many
  addresses, that stops at the first 429 and records the cap (per account and per IP). No cap within
  the bound is a finding. Capped so it never floods Resend.
- alert abuse (no session): the "unusual activity" alert endpoint hammered — a cap must appear.

Every rule that does not hold server-side is a finding; the run exits 1 on any finding. Capped at
`rate_per_second` requests (rules of engagement, docs/en/external-attack-campaigns.md). Needs
AUTH_TEST_PASSWORD for the session journeys. Standard library only.
"""

import argparse
import json
import os
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
USER_AGENT = "mairie360-business-campaign"


class RateLimiter:
    def __init__(self, rate):
        self._min = 1.0 / rate if rate > 0 else 0.0
        self._lock = threading.Lock()
        self._next = 0.0

    def wait(self):
        with self._lock:
            now = time.monotonic()
            start = max(now, self._next)
            self._next = start + self._min
        if start > now:
            time.sleep(start - now)


def _context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def http(method, url, limiter, headers=None, body=None, cookies=None, timeout=15):
    limiter.wait()
    data = None
    sent = {"User-Agent": USER_AGENT, "Accept": "application/json", **(headers or {})}
    if body is not None:
        data = json.dumps(body).encode()
        sent["Content-Type"] = "application/json"
    if cookies:
        sent["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
    req = urllib.request.Request(url, data=data, method=method, headers=sent)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_context()) as resp:
            return resp.status, resp.read(65536).decode("utf-8", "replace"), _set_cookies(resp.headers)
    except urllib.error.HTTPError as err:
        return err.code, err.read(65536).decode("utf-8", "replace"), _set_cookies(err.headers)
    except (urllib.error.URLError, OSError, ValueError) as err:
        return 0, str(err)[:200], {}


def _set_cookies(headers):
    jar = {}
    for raw in headers.get_all("Set-Cookie", []) if hasattr(headers, "get_all") else []:
        pair = raw.split(";", 1)[0].strip()
        if "=" in pair:
            name, value = pair.split("=", 1)
            jar[name] = value
    return jar


def front_url(cfg, front, path):
    return f"https://{front}.{cfg['domain']}{path}"


def sign_in(cfg, limiter):
    sessions = {}
    login = cfg["login"]
    password = os.environ.get("AUTH_TEST_PASSWORD", "")
    for role, email in cfg["accounts"].items():
        status, _, jar = http("POST", front_url(cfg, login["front"], login["path"]), limiter,
                              body={"email": email, "password": password, "device_info": "campaign"})
        token = jar.get(login["cookie"])
        if status == 200 and token:
            sessions[role] = {login["cookie"]: token}
    return sessions


def refused(status):
    return status in (400, 401, 403, 404, 405, 409, 410, 422)


def allowed(status):
    return 200 <= status < 300


# --------------------------------------------------------------------------- scenarios

def _extract_id(body, fields):
    try:
        doc = json.loads(body)
    except (ValueError, TypeError):
        return None
    for field in fields:
        if isinstance(doc, dict) and doc.get(field) not in (None, ""):
            return str(doc[field])
    return None


def run_sequence(cfg, limiter, sessions, seq):
    """Each step must meet its expected outcome; a bypassed rule is a finding."""
    out, obs = [], []
    cookies = sessions.get(seq["role"])
    if not cookies:
        return [f"sequence \"{seq['name']}\": could not sign in {seq['role']}"], obs
    resource_id = None
    setup = seq.get("setup")
    if setup:
        create = setup["create"]
        status, body, _ = http(create["method"], front_url(cfg, seq["front"], create["path"]), limiter,
                               cookies=cookies, body=create.get("body"))
        resource_id = _extract_id(body, setup.get("id_fields", ["id"]))
        obs.append({"setup": create["path"], "status": status, "id": resource_id})
        if not allowed(status) or not resource_id:
            return [f"sequence \"{seq['name']}\": setup did not create a resource (HTTP {status})"], obs
    for step in seq["steps"]:
        path = step["path"].replace("{id}", resource_id or "")
        status, _, _ = http(step["method"], front_url(cfg, seq["front"], path), limiter,
                            cookies=cookies, body=step.get("body"))
        obs.append({"step": step["name"], "method": step["method"], "status": status, "expect": step["expect"]})
        if step["expect"] == "refuse" and allowed(status):
            out.append(f"sequence \"{seq['name']}\": step \"{step['name']}\" was allowed (HTTP {status}), "
                       "the rule does not hold server-side")
        elif step["expect"] == "allow" and refused(status):
            out.append(f"sequence \"{seq['name']}\": the legitimate step \"{step['name']}\" was refused "
                       f"(HTTP {status})")
    cleanup = seq.get("cleanup")
    if cleanup and resource_id:
        http(cleanup["method"], front_url(cfg, seq["front"], cleanup["path"].replace("{id}", resource_id)),
             limiter, cookies=cookies)
    return out, obs


def email_abuse(cfg, limiter):
    """A forgot-password cap (429) must appear within the bound, on one account and sprayed."""
    out, obs = [], []
    fp = cfg["forgot_password"]
    url = front_url(cfg, fp["front"], fp["path"])
    for case in cfg.get("email_abuse", []):
        capped_at = None
        for i in range(case["max"]):
            email = cfg["accounts"][case["account"]] if case["mode"] == "single" \
                else f"attack.flood{i}@example.invalid"
            status, _, _ = http("POST", url, limiter, body={fp["field"]: email})
            if status == 429:
                capped_at = i + 1
                break
        obs.append({"case": case["name"], "mode": case["mode"], "capped_at": capped_at, "max": case["max"]})
        if case.get("expect_cap") and capped_at is None:
            out.append(f"email abuse \"{case['name']}\": no cap after {case['max']} forgot-password "
                       f"requests ({case['mode']}): Resend can be used to send e-mail in bulk")
    return out, obs


def alert_abuse(cfg, limiter):
    """The unusual-activity alert endpoint must be capped."""
    out, obs = [], []
    case = cfg.get("alert_abuse")
    if not case:
        return out, obs
    url = front_url(cfg, case["front"], case["path"])
    capped_at = None
    for i in range(case["max"]):
        status, _, _ = http(case["method"], url, limiter, body=case.get("body"))
        if status == 429:
            capped_at = i + 1
            break
    obs.append({"case": "alert abuse", "capped_at": capped_at, "max": case["max"]})
    if case.get("expect_cap") and capped_at is None:
        out.append(f"alert abuse: no cap after {case['max']} '{case['path']}' requests: the unusual-"
                   "activity alert can be spammed")
    return out, obs


# --------------------------------------------------------------------------- run and report

def run(cfg, limiter, sessions, skip):
    report = {"domain": cfg["domain"], "sequences": [], "deviations": []}
    if "sequences" not in skip:
        for seq in cfg.get("sequences", []):
            findings, obs = run_sequence(cfg, limiter, sessions, seq)
            report["sequences"].append({"name": seq["name"], "findings": findings, "observations": obs})
            report["deviations"] += findings
    if "email" not in skip:
        findings, obs = email_abuse(cfg, limiter)
        report["email_abuse"] = {"findings": findings, "observations": obs}
        report["deviations"] += findings
    if "alert" not in skip:
        findings, obs = alert_abuse(cfg, limiter)
        report["alert_abuse"] = {"findings": findings, "observations": obs}
        report["deviations"] += findings
    return report


def render_markdown(report):
    lines = [f"# External attack campaign — business logic, {report['date']}", "",
             f"Target: fronts of `{report['domain']}`.", ""]
    status = "FAILED" if report["deviations"] else "OK"
    lines += [f"**{status}**: {len(report['deviations'])} finding(s).", "", "## Findings", ""]
    lines += [f"- {d}" for d in report["deviations"]] or ["- none"]
    lines += ["", "## Sequences", ""]
    for seq in report["sequences"]:
        lines.append(f"- **{seq['name']}**: {'FAILED' if seq['findings'] else 'ok'}")
    lines.append("")
    return "\n".join(lines)


def main(argv=None):
    import datetime

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--expected", default=str(HERE / "expected.json"))
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--skip", default="", help="comma-separated: sequences, email, alert")
    args = parser.parse_args(argv)
    skip = {s for s in args.skip.split(",") if s}

    if not os.environ.get("AUTH_TEST_PASSWORD") and "sequences" not in skip:
        print("AUTH_TEST_PASSWORD is not set: cannot run the session journeys", file=sys.stderr)
        return 2
    cfg = json.loads(Path(args.expected).read_text())
    limiter = RateLimiter(cfg.get("rate_per_second", 5))
    sessions = sign_in(cfg, limiter) if "sequences" not in skip else {}
    report = run(cfg, limiter, sessions, skip)
    report["date"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (out / "report.md").write_text(render_markdown(report) + "\n")
    print(render_markdown(report))
    return 1 if report["deviations"] else 0


if __name__ == "__main__":
    sys.exit(main())
