"""Monthly external reconnaissance: parsing, deviations, month-over-month changes, whole run."""
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "security" / "external" / "recon" / "recon.py"
EXPECTED = ROOT / "security" / "external" / "recon" / "expected.json"
spec = importlib.util.spec_from_file_location("recon", SCRIPT)
recon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recon)

NMAP_XML = """<?xml version="1.0"?>
<nmaprun><host><address addr="203.0.113.10" addrtype="ipv4"/><ports>
<port protocol="tcp" portid="22"><state state="open"/></port>
<port protocol="tcp" portid="80"><state state="open"/></port>
<port protocol="tcp" portid="443"><state state="open"/></port>
<port protocol="tcp" portid="6443"><state state="filtered"/></port>
<port protocol="tcp" portid="8080"><state state="closed"/></port>
</ports></host></nmaprun>"""

EXPECTED_SMALL = {
    "zone": "example.test",
    "hosts": {"argocd": {"address": "203.0.113.1", "tcp": [22]},
              "prod": {"address": "203.0.113.10", "tcp": [22, 80, 443]}},
    "findings_to_close": {"tcp/22": "public SSH"},
    "subdomains": ["login.prod.example.test"],
    "accepted_leaks": [{"repo": "Old", "fingerprint": "abc:file:rule:1"}],
}


def observed(**overrides):
    base = {
        "ports": {"argocd": {"open": [22]}, "prod": {"open": [22, 80, 443]}},
        "subdomains": {"names": ["login.prod.example.test"]},
        "banners": {"https://login.prod.example.test/": []},
        "admin": {"Argo CD": {"reachable": False, "detail": "no answer"}},
        "leaks": {"repos": ["Deploiment"], "findings": []},
    }
    base.update(overrides)
    return base


class Parsing(unittest.TestCase):
    def test_mair_1186_open_ports_only(self):
        self.assertEqual(recon.parse_nmap_xml(NMAP_XML), [22, 80, 443])

    def test_mair_1186_certified_names_still_valid_in_the_zone(self):
        issuances = [
            {"not_after": "2027-01-01T00:00:00Z", "dns_names": ["login.prod.example.test", "*.dev.example.test"]},
            {"not_after": "2026-01-01T00:00:00Z", "dns_names": ["old.example.test"]},
            {"not_after": "2027-01-01T00:00:00Z", "dns_names": ["other.test", "EXAMPLE.TEST."]},
        ]
        self.assertEqual(recon.parse_certspotter(issuances, "example.test", "2026-11-26T00:00:00Z"),
                         ["dev.example.test", "example.test", "login.prod.example.test"])

    def test_mair_1186_banner_versions(self):
        leaks = recon.banner_leaks({"Server": "nginx/1.25.3", "X-Powered-By": "Next.js"},
                                   "<hr><address>Apache/2.4.58 (Debian)</address>")
        self.assertIn("header x-powered-by: Next.js", leaks)
        self.assertIn("header server: nginx/1.25.3", leaks)
        self.assertIn("error page: Apache/2.4.58", leaks)

    def test_mair_1186_product_without_version_is_not_a_leak(self):
        self.assertEqual(recon.banner_leaks({"Server": "traefik"}, "404 page not found"), [])


class Deviations(unittest.TestCase):
    def test_mair_1186_expected_state_passes(self):
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, observed()), [])

    def test_mair_1186_unexpected_port_fails(self):
        obs = observed(ports={"argocd": {"open": [22, 6443]}, "prod": {"open": [22, 80, 443, 5432]}})
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, obs),
                         ["argocd: unexpected open port tcp/6443", "prod: unexpected open port tcp/5432"])

    def test_mair_1186_closed_expected_port_is_not_a_deviation(self):
        obs = observed(ports={"argocd": {"open": []}, "prod": {"open": [443]}})
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, obs), [])

    def test_mair_1186_failed_or_missing_scan_fails(self):
        obs = observed(ports={"prod": {"error": "timeout"}})
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, obs),
                         ["argocd: not scanned", "prod: scan failed (timeout)"])

    def test_mair_1186_unexpected_subdomain_fails(self):
        obs = observed(subdomains={"names": ["login.prod.example.test", "argocd-hub.example.test"]})
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, obs),
                         ["subdomain not in the expected list: argocd-hub.example.test"])

    def test_mair_1186_subdomain_lookup_failure_fails(self):
        obs = observed(subdomains={"error": "Cert Spotter answered 429"})
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, obs),
                         ["subdomains: lookup failed (Cert Spotter answered 429)"])

    def test_mair_1186_banner_and_admin_interface_fail(self):
        obs = observed(banners={"https://x/": ["header server: nginx/1.25.3"]},
                       admin={"n8n editor": {"reachable": True, "detail": "HTTP 200 on https://n8n/"}})
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, obs), [
            "https://x/: header server: nginx/1.25.3",
            "admin interface reachable from the Internet: n8n editor (HTTP 200 on https://n8n/)"])

    def test_mair_1186_secret_fails_unless_accepted(self):
        leak = {"repo": "Deploiment", "rule": "github-pat", "file": "a.yaml", "line": 3,
                "commit": "0123456789abcdef", "fingerprint": "x"}
        accepted = dict(leak, repo="Old", fingerprint="abc:file:rule:1")
        obs = observed(leaks={"repos": ["Deploiment", "Old"], "findings": [leak, accepted]})
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, obs),
                         ["secret in Deploiment: github-pat at a.yaml:3 (commit 0123456789ab)"])

    def test_mair_1186_known_findings_listed_not_failed(self):
        self.assertEqual(recon.known_findings(EXPECTED_SMALL, observed()),
                         ["tcp/22 open on argocd, prod: public SSH"])


class Banners(unittest.TestCase):
    def test_mair_1186_unreachable_page_is_listed_not_failed(self):
        with mock.patch.object(recon, "http_get", side_effect=OSError("timed out")):
            banners, unreachable = recon.collect_banners({"banner_urls": ["https://n8n.example.test/"]})
        self.assertEqual(banners, {"https://n8n.example.test/": []})
        self.assertEqual(unreachable, ["https://n8n.example.test/: timed out"])
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, observed(banners=banners)), [])

    def test_mair_1186_version_header_fails(self):
        answers = [(200, {"Server": "nginx/1.25.3"}, ""), (404, {}, "Not Found")]
        with mock.patch.object(recon, "http_get", side_effect=answers):
            banners, _ = recon.collect_banners({"banner_urls": ["https://login.example.test/"]})
        self.assertEqual(recon.evaluate(EXPECTED_SMALL, observed(banners=banners)),
                         ["https://login.example.test/: header server: nginx/1.25.3"])

    def test_mair_1186_admin_interface_answering_fails(self):
        with mock.patch.object(recon, "http_get", return_value=(401, {}, "")):
            admin = recon.collect_admin({"admin_interfaces": [{"name": "Kubernetes API", "url": "https://x:6443/version"}]})
        self.assertTrue(admin["Kubernetes API"]["reachable"])
        with mock.patch.object(recon, "http_get", return_value=(502, {}, "")):
            admin = recon.collect_admin({"admin_interfaces": [{"name": "n8n", "url": "https://n8n/"}]})
        self.assertFalse(admin["n8n"]["reachable"])


class Changes(unittest.TestCase):
    def test_mair_1186_first_run(self):
        self.assertEqual(recon.changes_since(None, {"observed": observed(), "deviations": []}),
                         ["no previous report: first run"])

    def test_mair_1186_month_over_month(self):
        before = {"observed": observed(), "deviations": ["old finding"]}
        after = {"observed": observed(ports={"argocd": {"open": []}, "prod": {"open": [22, 80, 443, 8080]}},
                                      subdomains={"names": ["new.example.test"]}),
                 "deviations": ["prod: unexpected open port tcp/8080"]}
        self.assertEqual(recon.changes_since(before, after), [
            "argocd: tcp/22 closed",
            "prod: tcp/8080 opened",
            "subdomain appeared: new.example.test",
            "subdomain gone: login.prod.example.test",
            "new deviation: prod: unexpected open port tcp/8080",
            "deviation fixed: old finding"])

    def test_mair_1186_no_change(self):
        report = {"observed": observed(), "deviations": []}
        self.assertEqual(recon.changes_since(report, report), ["no change"])


class ExpectedList(unittest.TestCase):
    """The versioned list stays in the frame of the rules of engagement."""

    def setUp(self):
        self.expected = json.loads(EXPECTED.read_text())

    def test_mair_1186_mairie360_group_only(self):
        self.assertEqual(sorted(self.expected["hosts"]), ["argocd", "dev", "n8n", "prod", "staging"])
        for spec in self.expected["hosts"].values():
            self.assertTrue(spec["address"] == "212.47.242.79" or spec["address"].endswith(".mairie360-eip.fr"),
                            spec["address"])

    def test_mair_1186_rate_cap_of_the_rules_of_engagement(self):
        self.assertEqual(self.expected["max_rate"], 1)

    def test_mair_1186_admin_ports_never_expected_open(self):
        for host, spec in self.expected["hosts"].items():
            self.assertLessEqual(set(spec["tcp"]), {22, 80, 443}, host)
        self.assertEqual(self.expected["hosts"]["argocd"]["tcp"], [22])

    def test_mair_1186_scan_covers_admin_ports(self):
        ports = set()
        for part in self.expected["scan_ports"].split(","):
            low, _, high = part.partition("-")
            ports.update(range(int(low), int(high or low) + 1))
        self.assertLessEqual({22, 80, 443, 2379, 5432, 5678, 6379, 6443, 8080, 10250, 30080}, ports)

    def test_mair_1186_every_front_subdomain_expected(self):
        fronts = ["admin", "auth", "calendar", "dashboard", "elearning", "login", "message", "project", "settings"]
        for env in ("dev", "staging", "prod"):
            for front in fronts:
                self.assertIn(f"{front}.{env}.mairie360-eip.fr", self.expected["subdomains"])


class WholeRun(unittest.TestCase):
    """recon.py end to end with stubbed nmap, network and gitleaks."""

    def run_recon(self, nmap_xml, previous=None):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            nmap = tmp / "bin" / "nmap"
            nmap.parent.mkdir()
            (tmp / "scan.xml").write_text(nmap_xml)
            nmap.write_text(f"#!/bin/sh\necho \"$@\" >> {tmp}/nmap.args\ncat {tmp}/scan.xml\n")
            nmap.chmod(nmap.stat().st_mode | stat.S_IEXEC)
            expected = dict(EXPECTED_SMALL, max_rate=1, scan_ports="22,80,443,6443", banner_urls=[],
                            admin_interfaces=[], github_org="example")
            expected["hosts"] = {"prod": {"address": "203.0.113.10", "tcp": [22, 80, 443]}}
            (tmp / "expected.json").write_text(json.dumps(expected))
            args = ["--expected", str(tmp / "expected.json"), "--out-dir", str(tmp / "out"),
                    "--skip", "subdomains,gitleaks"]
            if previous:
                (tmp / "previous.json").write_text(json.dumps(previous))
                args += ["--previous", str(tmp / "previous.json")]
            with mock.patch.dict(os.environ, {"PATH": f"{nmap.parent}:{os.environ['PATH']}"}):
                code = recon.main(args)
            report = json.loads((tmp / "out" / "recon.json").read_text())
            markdown = (tmp / "out" / "recon.md").read_text()
            nmap_args = (tmp / "nmap.args").read_text()
        return code, report, markdown, nmap_args

    def test_mair_1186_clean_run_passes_and_writes_the_report(self):
        code, report, markdown, nmap_args = self.run_recon(NMAP_XML)
        self.assertEqual(code, 0)
        self.assertEqual(report["deviations"], [])
        self.assertIn("--max-rate 1 ", nmap_args)
        self.assertIn("-p 22,80,443,6443", nmap_args)
        self.assertIn("**OK**", markdown)
        self.assertIn("| prod | 22, 80, 443 |", markdown)
        self.assertIn("tcp/22 open on prod: public SSH", markdown)

    def test_mair_1186_new_port_fails_the_run_and_shows_the_change(self):
        _, previous, _, _ = self.run_recon(NMAP_XML)
        opened = NMAP_XML.replace('portid="6443"><state state="filtered"', 'portid="6443"><state state="open"')
        code, report, markdown, _ = self.run_recon(opened, previous=previous)
        self.assertEqual(code, 1)
        self.assertEqual(report["deviations"], ["prod: unexpected open port tcp/6443"])
        self.assertIn("prod: tcp/6443 opened", report["changes"])
        self.assertIn("**FAILED**", markdown)

    def test_mair_1186_cli_entrypoint(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--previous", result.stdout)


if __name__ == "__main__":
    unittest.main()
