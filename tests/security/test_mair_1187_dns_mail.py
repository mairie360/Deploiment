"""Monthly external reconnaissance, DNS part: orphan records and anti-spoofing records."""
import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "security" / "external" / "recon" / "recon.py"
EXPECTED = ROOT / "security" / "external" / "recon" / "expected.json"
spec = importlib.util.spec_from_file_location("recon_dns", SCRIPT)
recon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recon)

MAIL = {"dkim_selectors": ["resend"], "dmarc_policies": ["quarantine", "reject"]}
GOOD = {
    "example.test": ["v=spf1 include:amazonses.com -all", "google-site-verification=x"],
    "resend._domainkey.example.test": ["p=MIGfMA0"],
    "_dmarc.example.test": ["v=DMARC1; p=quarantine; rua=mailto:dmarc@example.test"],
}


def txt_from(table):
    return lambda name: table.get(name, [])


class MailAuth(unittest.TestCase):
    def test_mair_1187_enforced_domain_passes(self):
        self.assertEqual(recon.mail_auth_findings("example.test", MAIL, txt_from(GOOD)), [])

    def test_mair_1187_dmarc_none_fails(self):
        table = dict(GOOD, **{"_dmarc.example.test": ["v=DMARC1; p=none;"]})
        self.assertEqual(recon.mail_auth_findings("example.test", MAIL, txt_from(table)), [
            "example.test: DMARC p=none, expected quarantine or reject",
            "example.test: DMARC asks for no aggregate report (rua)",
        ])

    def test_mair_1187_reject_only_once_switched(self):
        spec = dict(MAIL, dmarc_policies=["reject"])
        self.assertEqual(recon.mail_auth_findings("example.test", spec, txt_from(GOOD)),
                         ["example.test: DMARC p=quarantine, expected reject"])

    def test_mair_1187_missing_spf_dkim_and_dmarc_fail(self):
        self.assertEqual(recon.mail_auth_findings("example.test", MAIL, txt_from({})), [
            "example.test: 0 SPF records (exactly one expected)",
            "example.test: no DKIM key for selector resend",
            "example.test: 0 DMARC records (exactly one expected)",
        ])

    def test_mair_1187_two_dmarc_records_fail(self):
        table = dict(GOOD, **{"_dmarc.example.test": GOOD["_dmarc.example.test"] * 2})
        self.assertEqual(recon.mail_auth_findings("example.test", MAIL, txt_from(table)),
                         ["example.test: 2 DMARC records (exactly one expected)"])

    def test_mair_1187_permissive_spf_fails(self):
        table = dict(GOOD, **{"example.test": ["v=spf1 +all"]})
        self.assertEqual(recon.mail_auth_findings("example.test", MAIL, txt_from(table)),
                         ["example.test: SPF does not end with -all or ~all: v=spf1 +all"])


class Records(unittest.TestCase):
    RECORDS = [
        {"name": "", "type": "A", "data": "203.0.113.10"},
        {"name": "login.prod", "type": "A", "data": "203.0.113.10"},
        {"name": "old", "type": "A", "data": "198.51.100.7"},
        {"name": "www", "type": "CNAME", "data": "example.test."},
        {"name": "docs", "type": "CNAME", "data": "gone.pages.example."},
        {"name": "", "type": "MX", "data": "10 mail.example.test."},
        {"name": "_dmarc", "type": "TXT", "data": "v=DMARC1; p=reject"},
    ]

    def test_mair_1187_orphan_address_and_dangling_target_fail(self):
        findings = recon.dns_record_findings("example.test", self.RECORDS, {"203.0.113.10"},
                                             lambda name: name != "gone.pages.example")
        self.assertEqual(findings, [
            "old.example.test A 198.51.100.7: not an address of the group (orphan record?)",
            "docs.example.test CNAME gone.pages.example: target does not resolve (takeover risk)",
        ])

    def test_mair_1187_zone_listing_reaches_the_report(self):
        expected = {"hosts": {"prod": {"address": "203.0.113.10"}},
                    "dns": {"zones": ["example.test"], "known_addresses": [],
                            "mail_domains": {"example.test": MAIL}}}
        with mock.patch.dict(os.environ, {"SCW_SECRET_KEY": "k"}), \
                mock.patch.object(recon, "lookup_txt", txt_from(GOOD)), \
                mock.patch.object(recon, "addresses_of", lambda name: {name}), \
                mock.patch.object(recon, "resolves", lambda name: True), \
                mock.patch.object(recon, "zone_records", lambda zone, key: self.RECORDS):
            observed = recon.collect_dns(expected)
        self.assertEqual(observed["zones"], {"example.test": 7})
        self.assertEqual(observed["deviations"],
                         ["old.example.test A 198.51.100.7: not an address of the group (orphan record?)"])
        report = {"date": "d", "observed": {"ports": {}, "dns": observed}, "known": [], "changes": [],
                  "deviations": recon.evaluate({"hosts": {}, "subdomains": []}, {"ports": {}, "dns": observed})}
        self.assertIn("old.example.test A 198.51.100.7: not an address of the group (orphan record?)", report["deviations"])
        self.assertIn("- example.test: 7 records", recon.render_markdown(report))

    def test_mair_1187_missing_key_is_a_deviation(self):
        expected = {"hosts": {}, "dns": {"zones": ["example.test"], "mail_domains": {}}}
        with mock.patch.dict(os.environ, {}, clear=True):
            observed = recon.collect_dns(expected)
        self.assertEqual(recon.evaluate({"hosts": {}}, {"ports": {}, "dns": observed}),
                         ["dns: SCW_SECRET_KEY not set: zone records not listed"])


class Expected(unittest.TestCase):
    def test_mair_1187_both_domains_checked_and_enforced(self):
        dns = json.loads(EXPECTED.read_text())["dns"]
        self.assertEqual(set(dns["zones"]), {"mairie360-eip.fr", "mairie360.fr"})
        for domain, mail in dns["mail_domains"].items():
            self.assertNotIn("none", mail["dmarc_policies"], domain)
            self.assertIn("resend", mail["dkim_selectors"], domain)


if __name__ == "__main__":
    unittest.main()
