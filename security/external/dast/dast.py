#!/usr/bin/env python3
"""Active DAST driver of the external attack campaigns.

    AUTH_TEST_PASSWORD=... security/external/dast/dast.py --out-dir report/ \
        [--zap zap-*.json] [--testssl testssl-*.json] [--sqlmap sqlmap.log]

Run by hand in an announced campaign window against the public front origins of staging (through
the ingress). The workflow (.github/workflows/external-dast.yaml) runs the heavy tools — ZAP
active scan with the CICD OpenAPI coverage hook, sqlmap, testssl.sh — and this driver:

1. runs its own HTTP-level checks against the fronts (standard library):
   - security headers (HSTS, CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy) and a
     CSP that forbids `unsafe-inline` / `unsafe-eval`;
   - the session cookie's flags (Secure, HttpOnly, SameSite) — missing any is High;
   - open redirect, path traversal and SSRF probes declared in expected.json;
2. folds every tool's report (ZAP JSON, testssl.sh JSON, sqlmap log) into the same findings list;
3. gates: any High alert fails the run (exit 1); a Medium is a finding for the register, not a
   failure (the rules of engagement forbid High alerts, docs/en/external-attack-campaigns.md).

Needs AUTH_TEST_PASSWORD (the plaintext of the test accounts' password) to sign a session in for
the authenticated probes. Standard library only.
"""

import argparse
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
USER_AGENT = "mairie360-dast-campaign"
SEVERITY_ORDER = {"high": 3, "medium": 2, "low": 1, "informational": 0}


def _context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


class _Passthrough(urllib.request.HTTPErrorProcessor):
    """Return every response as-is: do not follow redirects, do not raise on 3xx/4xx/5xx."""

    def http_response(self, request, response):
        return response

    https_response = http_response


def http(method, url, headers=None, body=None, cookies=None, timeout=15):
    """(status, headers_dict, body_text, set_cookies), redirects not followed. status 0 on a transport error."""
    data = None
    sent = {"User-Agent": USER_AGENT, **(headers or {})}
    if body is not None:
        data = json.dumps(body).encode()
        sent["Content-Type"] = "application/json"
    if cookies:
        sent["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=_context()), _Passthrough)
    req = urllib.request.Request(url, data=data, method=method, headers=sent)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read(65536).decode("utf-8", "replace"), _set_cookies(resp.headers)
    except (urllib.error.URLError, OSError, ValueError) as err:
        return 0, {}, str(err)[:200], []


def _set_cookies(headers):
    return headers.get_all("Set-Cookie", []) if hasattr(headers, "get_all") else []


def front_url(cfg, front, path=""):
    return f"https://{front}.{cfg['domain']}{path}"


def finding(severity, source, title, detail=""):
    return {"severity": severity, "source": source, "title": title, "detail": detail}


# --------------------------------------------------------------------------- HTTP-level checks

def ci(headers):
    return {k.lower(): v for k, v in headers.items()}


def header_findings(front, headers, cfg):
    out = []
    low = ci(headers)
    for name, rule in cfg["security_headers"].items():
        value = low.get(name)
        if value is None:
            out.append(finding(rule["severity"], "headers", f"{front}: missing header {name}"))
            continue
        if "equals" in rule and value.strip().lower() != rule["equals"].lower():
            out.append(finding(rule["severity"], "headers", f"{front}: {name} is \"{value}\", expected {rule['equals']}"))
        if "any_of" in rule and value.strip().upper() not in [v.upper() for v in rule["any_of"]]:
            out.append(finding(rule["severity"], "headers", f"{front}: {name} is \"{value}\", expected one of {rule['any_of']}"))
        if "min_max_age" in rule:
            match = re.search(r"max-age=(\d+)", value)
            if not match or int(match.group(1)) < rule["min_max_age"]:
                out.append(finding(rule["severity"], "headers", f"{front}: {name} max-age below {rule['min_max_age']} (\"{value}\")"))
    csp = low.get("content-security-policy", "")
    for token in cfg.get("csp_forbidden", []):
        if token in csp:
            out.append(finding("medium", "headers", f"{front}: CSP allows {token}"))
    return out


def cookie_findings(front, set_cookies, cfg):
    out = []
    name = cfg["login"]["cookie"]
    header = next((c for c in set_cookies if c.split("=", 1)[0].strip() == name), None)
    if header is None:
        return out
    attrs = [a.strip().lower() for a in header.split(";")[1:]]
    for flag in cfg["session_cookie_flags"]:
        present = any(a == flag.lower() or a.startswith(flag.lower() + "=") for a in attrs)
        if not present:
            out.append(finding("high", "cookie", f"{front}: session cookie {name} without {flag}"))
    return out


def open_redirect_findings(cfg, sessions):
    out = []
    for case in cfg.get("open_redirect", []):
        cookies = sessions.get(case["role"])
        url = front_url(cfg, case["front"], case["path"]) + f"?{case['param']}={case['payload']}"
        status, headers, _, _ = http(case["method"], url, cookies=cookies)
        location = ci(headers).get("location", "")
        if 300 <= status < 400 and case["payload"].split("//")[-1].split("/")[0] in location:
            out.append(finding("medium", "redirect", f"{case['front']}: open redirect on {case['path']}?{case['param']}",
                               f"Location: {location}"))
    return out


def path_traversal_findings(cfg, sessions):
    out = []
    for case in cfg.get("path_traversal", []):
        cookies = sessions.get(case["role"])
        url = front_url(cfg, case["front"], case["path_template"].replace("{p}", case["payload"]))
        status, _, body, _ = http(case["method"], url, cookies=cookies)
        if 200 <= status < 300 and any(re.search(sig, body) for sig in case["leak_signatures"]):
            out.append(finding("high", "path-traversal", f"{case['front']}: path traversal on {case['path_template']}",
                               f"HTTP {status}, leak signature matched"))
    return out


def ssrf_findings(cfg, sessions):
    out = []
    for case in cfg.get("ssrf", []):
        cookies = sessions.get(case["role"])
        status, _, body, _ = http(case["method"], front_url(cfg, case["front"], case["path"]), cookies=cookies,
                                  body={case["url_field"]: case["payload"]})
        if 200 <= status < 300 and any(sig in body for sig in case["leak_signatures"]):
            out.append(finding("high", "ssrf", f"{case['front']}: SSRF on {case['path']} ({case['url_field']})",
                               f"HTTP {status}, internal metadata reflected"))
    return out


# --------------------------------------------------------------------------- tool report parsers

def parse_zap(report):
    """ZAP JSON report (`site[].alerts[]`, riskcode 0-3) → findings."""
    risk = {"3": "high", "2": "medium", "1": "low", "0": "informational"}
    out = []
    for site in report.get("site", []):
        host = site.get("@name", "")
        for alert in site.get("alerts", []):
            sev = risk.get(str(alert.get("riskcode", "0")), "informational")
            out.append(finding(sev, "zap", f"{host}: {alert.get('alert', alert.get('name', 'alert'))}",
                               f"{len(alert.get('instances', []))} instance(s)"))
    return out


def parse_testssl(entries):
    """testssl.sh --jsonfile list of {id, severity, finding} → findings (CRITICAL/HIGH → high)."""
    level = {"CRITICAL": "high", "HIGH": "high", "MEDIUM": "medium", "LOW": "low"}
    out = []
    for entry in entries:
        sev = level.get(str(entry.get("severity", "")).upper())
        if sev:
            out.append(finding(sev, "testssl", f"{entry.get('ip', '')}: {entry.get('id', '')}",
                               str(entry.get("finding", ""))))
    return out


def parse_sqlmap(text):
    """sqlmap stdout/log → one high finding per parameter reported injectable."""
    out = []
    for match in re.finditer(r"Parameter: ([^\s]+) \(([^)]+)\)", text):
        if "is vulnerable" in text or "injectable" in text.lower():
            out.append(finding("high", "sqlmap", f"injectable parameter {match.group(1)} ({match.group(2)})"))
    return out


# --------------------------------------------------------------------------- run and report

def run_http_checks(cfg, sessions):
    out = []
    for front in cfg["fronts"]:
        status, headers, _, set_cookies = http("GET", front_url(cfg, front, "/"))
        if status == 0:
            out.append(finding("informational", "headers", f"{front}: not reachable", headers if isinstance(headers, str) else ""))
            continue
        out += header_findings(front, headers, cfg)
    # The session cookie is read from the login response, once.
    login = cfg["login"]
    _, _, _, login_cookies = http("POST", front_url(cfg, login["front"], login["path"]),
                                  body={"email": cfg["accounts"]["user"], "password": os.environ["AUTH_TEST_PASSWORD"],
                                        "device_info": "campaign"})
    out += cookie_findings(login["front"], login_cookies, cfg)
    out += open_redirect_findings(cfg, sessions)
    out += path_traversal_findings(cfg, sessions)
    out += ssrf_findings(cfg, sessions)
    return out


def sign_in(cfg):
    sessions = {}
    login = cfg["login"]
    for role, email in cfg["accounts"].items():
        status, _, _, set_cookies = http("POST", front_url(cfg, login["front"], login["path"]),
                                         body={"email": email, "password": os.environ["AUTH_TEST_PASSWORD"],
                                               "device_info": "campaign"})
        token = _cookie_value(set_cookies, login["cookie"])
        if status == 200 and token:
            sessions[role] = {login["cookie"]: token}
    return sessions


def _cookie_value(set_cookies, name):
    for raw in set_cookies:
        pair = raw.split(";", 1)[0].strip()
        if pair.split("=", 1)[0] == name and "=" in pair:
            return pair.split("=", 1)[1]
    return None


def gate(findings):
    """Sorted most-severe first; the run fails on any High."""
    ordered = sorted(findings, key=lambda f: -SEVERITY_ORDER.get(f["severity"], 0))
    failed = any(f["severity"] == "high" for f in findings)
    return ordered, failed


def render_markdown(report):
    lines = [f"# External attack campaign — active DAST, {report['date']}", "",
             f"Target: fronts of `{report['domain']}`.", ""]
    counts = {s: sum(1 for f in report["findings"] if f["severity"] == s) for s in SEVERITY_ORDER}
    status = "FAILED" if report["failed"] else "OK"
    lines += [f"**{status}**: {counts['high']} High, {counts['medium']} Medium, {counts['low']} Low, "
              f"{counts['informational']} Info.", "", "## Findings", ""]
    for f in report["findings"]:
        detail = f" — {f['detail']}" if f["detail"] else ""
        lines.append(f"- **{f['severity'].upper()}** [{f['source']}] {f['title']}{detail}")
    if not report["findings"]:
        lines.append("- none")
    lines.append("")
    return "\n".join(lines)


def main(argv=None):
    import datetime

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--expected", default=str(HERE / "expected.json"))
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--zap", action="append", default=[], help="ZAP JSON report(s)")
    parser.add_argument("--testssl", action="append", default=[], help="testssl.sh JSON report(s)")
    parser.add_argument("--sqlmap", action="append", default=[], help="sqlmap log(s)")
    parser.add_argument("--skip-http", action="store_true", help="skip the driver's own HTTP checks")
    args = parser.parse_args(argv)

    if not args.skip_http and not os.environ.get("AUTH_TEST_PASSWORD"):
        print("AUTH_TEST_PASSWORD is not set: cannot sign in for the HTTP checks", file=sys.stderr)
        return 2
    cfg = json.loads(Path(args.expected).read_text())

    findings = []
    if not args.skip_http:
        sessions = sign_in(cfg)
        findings += run_http_checks(cfg, sessions)
    for path in args.zap:
        findings += parse_zap(json.loads(Path(path).read_text()))
    for path in args.testssl:
        findings += parse_testssl(json.loads(Path(path).read_text()))
    for path in args.sqlmap:
        findings += parse_sqlmap(Path(path).read_text())

    ordered, failed = gate(findings)
    report = {"domain": cfg["domain"], "findings": ordered, "failed": failed,
              "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")}
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (out / "report.md").write_text(render_markdown(report) + "\n")
    print(render_markdown(report))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
