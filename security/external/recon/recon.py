#!/usr/bin/env python3
"""Monthly reconnaissance of the mairie360 group: what an attacker sees before attacking.

    security/external/recon/recon.py --out-dir report/ [--previous prev/recon.json] [--skip gitleaks]

Reads expected.json (next to this file, or --expected) and collects, from the Internet:

- ports: TCP connect scan of every machine (nmap, `max_rate` probes per second and per host,
  the cap of the rules of engagement, machines scanned in parallel);
- subdomains: names of the certificates still valid in the certificate transparency logs
  (Cert Spotter API);
- banners: `Server`, `X-Powered-By` and similar headers, and version strings in error pages;
- admin interfaces: URLs that must not answer from the Internet;
- leaks: gitleaks on the full history of every public repository of the GitHub org
  (docker image pinned by digest, like mairie360/CICD's gitleaks action).

Writes recon.json and recon.md to --out-dir, with the changes since --previous (the report of
the previous run), and exits 1 when anything deviates from the expected list. The rules of
engagement are docs/en/external-attack-campaigns.md: reconnaissance only targets the
mairie360 group, never a client.

Standard library only.
"""

import argparse
import concurrent.futures
import datetime
import json
import os
import re
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
GITLEAKS_IMAGE = ("zricethezav/gitleaks:v8.30.1@sha256:"
                  "c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f")
USER_AGENT = "mairie360-external-recon"
# Headers that only exist to name a product or its version.
PRODUCT_HEADERS = ("x-powered-by", "x-aspnet-version", "x-aspnetmvc-version", "x-generator",
                   "x-runtime", "x-version")
# A product name followed by a version number: "nginx/1.25.3", "Express 4.18", "PHP/8.2.1".
VERSION = re.compile(r"\b([A-Za-z][\w.-]*)[/ ]v?(\d+\.\d+(?:\.\d+)*)\b")


# --------------------------------------------------------------------------- parsing

def parse_nmap_xml(text):
    """Open TCP ports of the single host of an nmap -oX report."""
    root = ET.fromstring(text)
    ports = []
    for port in root.iter("port"):
        state = port.find("state")
        if port.get("protocol") == "tcp" and state is not None and state.get("state") == "open":
            ports.append(int(port.get("portid")))
    return sorted(ports)


def parse_certspotter(issuances, zone, now):
    """Names under `zone` of the certificates still valid at `now` (ISO 8601 UTC)."""
    names = set()
    for issuance in issuances:
        if issuance.get("not_after", "") <= now:
            continue
        for name in issuance.get("dns_names", []):
            name = name.lower().rstrip(".")
            if name.startswith("*."):
                name = name[2:]
            if name == zone or name.endswith("." + zone):
                names.add(name)
    return sorted(names)


def banner_leaks(headers, error_body):
    """What the headers and an error page tell about the software and its version."""
    leaks = []
    lower = {k.lower(): v for k, v in headers.items()}
    for name in PRODUCT_HEADERS:
        if name in lower:
            leaks.append(f"header {name}: {lower[name]}")
    server = lower.get("server", "")
    if VERSION.search(server):
        leaks.append(f"header server: {server}")
    for match in sorted(set(m.group(0) for m in VERSION.finditer(error_body or ""))):
        leaks.append(f"error page: {match}")
    return leaks


def accepted(finding, accepted_leaks):
    """A gitleaks finding listed in accepted_leaks (repository + fingerprint)."""
    return any(a.get("repo") == finding["repo"] and a.get("fingerprint") == finding["fingerprint"]
               for a in accepted_leaks)


# --------------------------------------------------------------------------- evaluation

def evaluate(expected, observed):
    """[deviation, ...]: everything observed that the expected list does not allow."""
    deviations = []
    for host, spec in expected["hosts"].items():
        seen = observed["ports"].get(host)
        if seen is None:
            deviations.append(f"{host}: not scanned")
            continue
        if "error" in seen:
            deviations.append(f"{host}: scan failed ({seen['error']})")
            continue
        for port in sorted(set(seen["open"]) - set(spec["tcp"])):
            deviations.append(f"{host}: unexpected open port tcp/{port}")
    if "subdomains" in observed:
        if "error" in observed["subdomains"]:
            deviations.append(f"subdomains: lookup failed ({observed['subdomains']['error']})")
        else:
            for name in sorted(set(observed["subdomains"]["names"]) - set(expected["subdomains"])):
                deviations.append(f"subdomain not in the expected list: {name}")
    for url, leaks in sorted(observed.get("banners", {}).items()):
        for leak in leaks:
            deviations.append(f"{url}: {leak}")
    for name, state in sorted(observed.get("admin", {}).items()):
        if state.get("reachable"):
            deviations.append(f"admin interface reachable from the Internet: {name} ({state['detail']})")
    if "leaks" in observed:
        if "error" in observed["leaks"]:
            deviations.append(f"gitleaks: {observed['leaks']['error']}")
        for finding in observed["leaks"].get("findings", []):
            if not accepted(finding, expected.get("accepted_leaks", [])):
                deviations.append(f"secret in {finding['repo']}: {finding['rule']} at "
                                  f"{finding['file']}:{finding['line']} (commit {finding['commit'][:12]})")
    return deviations


def known_findings(expected, observed):
    """Expected but still worth reporting every run (findings_to_close)."""
    notes = []
    for key, why in expected.get("findings_to_close", {}).items():
        proto, _, port = key.partition("/")
        hosts = [h for h, seen in observed["ports"].items()
                 if proto == "tcp" and int(port) in seen.get("open", [])]
        if hosts:
            notes.append(f"{key} open on {', '.join(sorted(hosts))}: {why}")
    return notes


def changes_since(previous, current):
    """[change, ...] between two reports (observations only, both sides)."""
    if not previous:
        return ["no previous report: first run"]
    out = []
    prev_obs, cur_obs = previous.get("observed", {}), current["observed"]
    for host in sorted(set(prev_obs.get("ports", {})) | set(cur_obs.get("ports", {}))):
        before = set(prev_obs.get("ports", {}).get(host, {}).get("open", []))
        after = set(cur_obs.get("ports", {}).get(host, {}).get("open", []))
        out += [f"{host}: tcp/{p} opened" for p in sorted(after - before)]
        out += [f"{host}: tcp/{p} closed" for p in sorted(before - after)]
    before = set(prev_obs.get("subdomains", {}).get("names", []))
    after = set(cur_obs.get("subdomains", {}).get("names", []))
    out += [f"subdomain appeared: {n}" for n in sorted(after - before)]
    out += [f"subdomain gone: {n}" for n in sorted(before - after)]
    before, after = set(previous.get("deviations", [])), set(current["deviations"])
    out += [f"new deviation: {d}" for d in sorted(after - before)]
    out += [f"deviation fixed: {d}" for d in sorted(before - after)]
    return out or ["no change"]


def render_markdown(report):
    lines = [f"# External reconnaissance, {report['date']}", ""]
    status = "FAILED" if report["deviations"] else "OK"
    lines += [f"**{status}**: {len(report['deviations'])} deviation(s) from `expected.json`.", ""]
    for title, key in (("Deviations", "deviations"), ("Known findings, still open", "known"),
                       ("Changes since the previous run", "changes")):
        lines += [f"## {title}", ""]
        lines += [f"- {item}" for item in report[key]] or ["- none"]
        lines.append("")
    obs = report["observed"]
    lines += ["## Open ports", "", "| Machine | Open TCP ports |", "| --- | --- |"]
    for host, seen in sorted(obs["ports"].items()):
        lines.append(f"| {host} | {seen.get('error') or ', '.join(map(str, seen['open'])) or 'none'} |")
    lines.append("")
    if "subdomains" in obs:
        lines += ["## Certified subdomains", ""]
        lines += [f"- {n}" for n in obs["subdomains"].get("names", [])] or ["- none"]
        lines.append("")
    if obs.get("unreachable"):
        lines += ["## Unreachable pages (not a deviation)", ""]
        lines += [f"- {u}" for u in obs["unreachable"]]
        lines.append("")
    if "leaks" in obs:
        lines += ["## Public repositories scanned by gitleaks", "",
                  ", ".join(obs["leaks"].get("repos", [])) or "none", ""]
    return "\n".join(lines)


# --------------------------------------------------------------------------- collection

def http_get(url, timeout=15, headers=None):
    """(status, headers, body) of a GET, certificate not checked: we look, we do not trust."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.status, dict(resp.headers), resp.read(65536).decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), err.read(65536).decode("utf-8", "replace")


def scan_host(spec, expected):
    cmd = ["nmap", "-Pn", "-sT", "-n", "--max-rate", str(expected["max_rate"]),
           "-p", expected["scan_ports"], "-oX", "-", spec["address"]]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=4 * 3600, check=True)
        return {"address": spec["address"], "open": parse_nmap_xml(result.stdout)}
    except (OSError, subprocess.SubprocessError, ET.ParseError) as err:
        return {"address": spec["address"], "error": (str(err).splitlines() or ["?"])[0][:200]}


def collect_ports(expected):
    """One nmap per machine, all at once: the rate cap is per host."""
    hosts = expected["hosts"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(hosts))) as pool:
        futures = {host: pool.submit(scan_host, spec, expected) for host, spec in hosts.items()}
        return {host: future.result() for host, future in futures.items()}


def collect_subdomains(expected, now):
    zone = expected["zone"]
    issuances, after = [], None
    try:
        while True:
            query = {"domain": zone, "include_subdomains": "true", "expand": "dns_names"}
            if after:
                query["after"] = after
            status, _, body = http_get("https://api.certspotter.com/v1/issuances?"
                                       + urllib.parse.urlencode(query), timeout=60)
            if status != 200:
                return {"error": f"Cert Spotter answered {status}"}
            page = json.loads(body)
            if not page:
                break
            issuances += page
            after = page[-1]["id"]
    except (OSError, ValueError, KeyError) as err:
        return {"error": str(err)[:200]}
    return {"names": parse_certspotter(issuances, zone, now)}


def collect_banners(expected):
    out, unreachable = {}, []
    for url in expected["banner_urls"]:
        try:
            _, headers, _ = http_get(url)
            _, _, error_body = http_get(urllib.parse.urljoin(url, f"/{secrets.token_hex(8)}-not-found"))
            out[url] = banner_leaks(headers, error_body)
        except (OSError, ValueError) as err:
            # Nothing shown, nothing leaked: listed in the report, not a deviation.
            out[url] = []
            unreachable.append(f"{url}: {str(err)[:120]}")
    return out, unreachable


def collect_admin(expected):
    out = {}
    for item in expected["admin_interfaces"]:
        try:
            status, _, _ = http_get(item["url"], timeout=10)
            # A 5xx from the ingress is not the interface itself answering.
            out[item["name"]] = {"reachable": status < 500, "detail": f"HTTP {status} on {item['url']}"}
        except (OSError, ValueError) as err:
            out[item["name"]] = {"reachable": False, "detail": f"no answer ({str(err)[:120]})"}
    return out


def public_repos(org, token):
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    repos, page = [], 1
    while True:
        status, _, body = http_get(f"https://api.github.com/orgs/{org}/repos?type=public&per_page=100&page={page}",
                                   timeout=30, headers=headers)
        if status != 200:
            raise ValueError(f"GitHub answered {status}")
        batch = json.loads(body)
        if not batch:
            return sorted(r["name"] for r in repos)
        repos += batch
        page += 1


def collect_leaks(expected):
    org = expected["github_org"]
    try:
        repos = public_repos(org, os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))
    except (OSError, ValueError, KeyError, TypeError) as err:
        return {"error": f"cannot list the public repositories ({str(err)[:120]})", "findings": []}
    findings, errors = [], []
    with tempfile.TemporaryDirectory() as work:
        for repo in repos:
            src = Path(work) / repo
            try:
                subprocess.run(["git", "clone", "--quiet", f"https://github.com/{org}/{repo}.git", str(src)],
                               check=True, capture_output=True, timeout=900)
                report = Path(work) / f"{repo}.json"
                # Exit code 1 = leaks found; the report says which.
                subprocess.run(["docker", "run", "--rm", "-v", f"{work}:/work", GITLEAKS_IMAGE, "git",
                                f"/work/{repo}", "--no-banner", "--redact", "--exit-code", "0",
                                "--report-format", "json", "--report-path", f"/work/{repo}.json"],
                               check=True, capture_output=True, timeout=1800)
                for leak in json.loads(report.read_text() or "[]"):
                    findings.append({"repo": repo, "rule": leak.get("RuleID", ""), "file": leak.get("File", ""),
                                     "line": leak.get("StartLine", 0), "commit": leak.get("Commit", ""),
                                     "fingerprint": leak.get("Fingerprint", "")})
            except (OSError, subprocess.SubprocessError, ValueError) as err:
                errors.append(f"{repo}: {str(err)[:120]}")
            finally:
                shutil.rmtree(src, ignore_errors=True)
    out = {"repos": repos, "findings": findings}
    if errors:
        out["error"] = "; ".join(errors)
    return out


# --------------------------------------------------------------------------- main

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--expected", default=str(HERE / "expected.json"))
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--previous", help="recon.json of the previous run")
    parser.add_argument("--skip", default="", help="comma-separated: ports,subdomains,banners,admin,gitleaks")
    args = parser.parse_args(argv)
    skip = {s for s in args.skip.split(",") if s}

    expected = json.loads(Path(args.expected).read_text())
    now = datetime.datetime.now(datetime.timezone.utc)
    observed = {"ports": {} if "ports" in skip else collect_ports(expected)}
    if "subdomains" not in skip:
        observed["subdomains"] = collect_subdomains(expected, now.strftime("%Y-%m-%dT%H:%M:%SZ"))
    if "banners" not in skip:
        observed["banners"], observed["unreachable"] = collect_banners(expected)
    if "admin" not in skip:
        observed["admin"] = collect_admin(expected)
    if "gitleaks" not in skip:
        observed["leaks"] = collect_leaks(expected)
    if "ports" in skip:
        expected = {**expected, "hosts": {}}

    report = {"date": now.strftime("%Y-%m-%d %H:%M UTC"), "observed": observed,
              "deviations": evaluate(expected, observed), "known": known_findings(expected, observed)}
    previous = None
    if args.previous and Path(args.previous).is_file():
        previous = json.loads(Path(args.previous).read_text())
    report["changes"] = changes_since(previous, report)

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "recon.json").write_text(json.dumps(report, indent=2) + "\n")
    (out / "recon.md").write_text(render_markdown(report) + "\n")
    print(render_markdown(report))
    return 1 if report["deviations"] else 0


if __name__ == "__main__":
    sys.exit(main())
