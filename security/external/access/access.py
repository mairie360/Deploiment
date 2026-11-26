#!/usr/bin/env python3
"""Behavioural access-control scenarios of the external attack campaigns.

    AUTH_TEST_PASSWORD=... security/external/access/access.py --out-dir report/ [--skip idor]

Replays, against a deployed instance through its FRONT origins (staging, expected.json `domain`),
what an under-privileged attacker tries once signed in. The per-API `access-matrix.yaml` are the
source of the expected allow/deny, but the front paths are BFF-reshaped, so they are the fronts'
own CRUD paths, not a 1:1 map of the matrices (matrix completeness stays enforced per-API by each
API's tests/endpoints/access_matrix.rs). Three families:

- elevation: a Guest session must not reach the /api/v1/admin scope (the admin front's operations
  must all answer 403 / 401 to a Guest);
- IDOR, with runtime discovery: one account creates a resource through its front and keeps its id;
  another account must not read, change or delete it, and must never see its data;
- (elevation covers the out-of-role write: a Guest writing through the admin front).

Each weakness is a deviation: the report (report.json / report.md, --out-dir) lists them and the
script exits 1, for the findings register. Fixing one is its own ticket. Capped at `rate_per_second`
requests (rules of engagement, docs/en/external-attack-campaigns.md). Needs AUTH_TEST_PASSWORD (the
plaintext of the test accounts' password) to sign the sessions in; without it nothing can run.
Standard library only.
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
USER_AGENT = "mairie360-access-campaign"


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
    """(status, body_text, set_cookies) of one request; status 0 on a transport error."""
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


def login(cfg, limiter, email, password):
    """The session cookie of a test account, or None."""
    login_cfg = cfg["login"]
    status, _, jar = http("POST", front_url(cfg, login_cfg["front"], login_cfg["path"]), limiter,
                          body={"email": email, "password": password, "device_info": "campaign"})
    token = jar.get(login_cfg["cookie"])
    return {login_cfg["cookie"]: token} if status == 200 and token else None


def is_refused(status):
    return status in (401, 403)


def is_allowed(status):
    return 200 <= status < 300


# --------------------------------------------------------------------------- scenarios

def elevation(cfg, limiter, sessions):
    """A Guest session must be refused on every admin-front operation."""
    out, obs = [], []
    spec = cfg["elevation"]
    cookies = sessions.get(spec["role"])
    if not cookies:
        return [f"elevation: could not sign in the {spec['role']} account"], obs
    for probe in spec["probes"]:
        status, _, _ = http(probe["method"], front_url(cfg, probe["front"], probe["path"]), limiter,
                            cookies=cookies, body=probe.get("body"))
        obs.append({"probe": probe["name"], "status": status})
        if is_allowed(status):
            out.append(f"elevation: a {spec['role']} reaches the admin operation \"{probe['name']}\" "
                       f"({probe['method']} {probe['path']}) → HTTP {status}, expected 403")
    return out, obs


def _extract_id(body, fields):
    try:
        doc = json.loads(body)
    except (ValueError, TypeError):
        return None
    for field in fields:
        if isinstance(doc, dict) and doc.get(field) not in (None, ""):
            return str(doc[field])
    return None


def idor(cfg, limiter, sessions):
    """A resource created by one account must be unreachable to another, with no data leak."""
    out, obs = [], []
    for case in cfg["idor"]:
        owner = sessions.get(case["owner_role"])
        other = sessions.get(case["other_role"])
        if not owner or not other:
            out.append(f"idor: could not sign in {case['owner_role']} or {case['other_role']} for "
                       f"\"{case['name']}\"")
            continue
        create = case["create"]
        status, body, _ = http(create["method"], front_url(cfg, case["front"], create["path"]), limiter,
                               cookies=owner, body=create.get("body"))
        resource_id = _extract_id(body, case["id_fields"])
        obs.append({"case": case["name"], "create_status": status, "id": resource_id})
        if not is_allowed(status) or not resource_id:
            out.append(f"idor: could not create the resource for \"{case['name']}\" "
                       f"(HTTP {status}); scenario not conclusive")
            continue
        marker = case.get("marker")
        for op in case["access"]:
            path = op["path"].replace("{id}", resource_id)
            status, body, _ = http(op["method"], front_url(cfg, case["front"], path), limiter,
                                   cookies=other, body=op.get("body"))
            leaked = bool(marker and is_allowed(status) and marker in body)
            obs.append({"case": case["name"], "op": f"{op['method']} {path}", "status": status,
                        "role": case["other_role"], "leaked": leaked})
            if is_allowed(status):
                detail = "and the answer carries its data" if leaked else "no data checked"
                out.append(f"idor: {case['other_role']} {op['method']} another account's "
                           f"\"{case['name']}\" → HTTP {status} ({detail})")
        # Best-effort cleanup, as the owner.
        cleanup = case.get("cleanup")
        if cleanup:
            http(cleanup["method"], front_url(cfg, case["front"], cleanup["path"].replace("{id}", resource_id)),
                 limiter, cookies=owner)
    return out, obs


SCENARIOS = {"elevation": elevation, "idor": idor}


# --------------------------------------------------------------------------- run and report

def run(cfg, limiter, sessions, skip):
    report = {"domain": cfg["domain"], "scenarios": {}, "deviations": []}
    for name, func in SCENARIOS.items():
        if name in skip:
            report["scenarios"][name] = {"skipped": True}
            continue
        findings, obs = func(cfg, limiter, sessions)
        report["scenarios"][name] = {"findings": findings, "observations": obs}
        report["deviations"] += findings
    return report


def render_markdown(report):
    lines = [f"# External attack campaign — access control, {report['date']}", "",
             f"Target: fronts of `{report['domain']}`.", ""]
    status = "FAILED" if report["deviations"] else "OK"
    lines += [f"**{status}**: {len(report['deviations'])} finding(s).", "", "## Findings", ""]
    lines += [f"- {d}" for d in report["deviations"]] or ["- none"]
    lines += ["", "## Scenarios", ""]
    for name, result in report["scenarios"].items():
        if result.get("skipped"):
            lines.append(f"- **{name}**: skipped")
        else:
            lines.append(f"- **{name}**: {'FAILED' if result['findings'] else 'ok'} "
                         f"({len(result['findings'])} finding(s))")
    lines.append("")
    return "\n".join(lines)


def sign_in_all(cfg, limiter, password):
    return {role: login(cfg, limiter, email, password) for role, email in cfg["accounts"].items()}


def main(argv=None):
    import datetime

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--expected", default=str(HERE / "expected.json"))
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--skip", default="", help="comma-separated: " + ", ".join(SCENARIOS))
    args = parser.parse_args(argv)
    skip = {s for s in args.skip.split(",") if s}

    password = os.environ.get("AUTH_TEST_PASSWORD")
    if not password:
        print("AUTH_TEST_PASSWORD is not set: cannot sign the test accounts in", file=sys.stderr)
        return 2

    cfg = json.loads(Path(args.expected).read_text())
    limiter = RateLimiter(cfg.get("rate_per_second", 5))
    sessions = sign_in_all(cfg, limiter, password)
    report = run(cfg, limiter, sessions, skip)
    report["signed_in"] = sorted(role for role, c in sessions.items() if c)
    report["date"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (out / "report.md").write_text(render_markdown(report) + "\n")
    print(render_markdown(report))
    return 1 if report["deviations"] else 0


if __name__ == "__main__":
    sys.exit(main())
