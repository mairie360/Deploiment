"""Tests of scripts/check-compliance.py (MAIR-294): python3 -m unittest discover tests/compliance."""
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
spec = importlib.util.spec_from_file_location("check_compliance", os.path.join(REPO, "scripts", "check-compliance.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def render(env="prod"):
    files = subprocess.run(["./scripts/instance-values.sh", f"clusters/mairie360/instances/{env}"], cwd=REPO, check=True, capture_output=True, text=True).stdout.split()
    args = ["helm", "template", "r", "./charts/mairie360-stack"]
    for f in files:
        args += ["-f", f]
    return subprocess.run(args, cwd=REPO, check=True, capture_output=True, text=True).stdout


class CheckComplianceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = render()

    def setUp(self):
        self.root = tempfile.mkdtemp()
        shutil.copytree(os.path.join(REPO, "compliance", "mairie360"), os.path.join(self.root, "compliance", "mairie360"))
        os.makedirs(os.path.join(self.root, "clusters", "mairie360"))
        self.file = os.path.join(self.root, "prod.yaml")
        with open(self.file, "w", encoding="utf-8") as handle:
            handle.write(self.rendered)
        check.ROOT = self.root
        # Only prod is rendered here (once, setUpClass).
        self.edit("retention.yaml", "applies_to: [dev, staging, prod]", "applies_to: [prod]")

    def tearDown(self):
        shutil.rmtree(self.root)
        check.ROOT = REPO

    def edit(self, name, old, new):
        path = os.path.join(self.root, "compliance", "mairie360", name)
        text = open(path, encoding="utf-8").read()
        self.assertIn(old, text)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text.replace(old, new))

    def run_check(self, strict=False):
        report = check.Report(strict)
        check.check_org("mairie360", report, {"mairie360/prod": self.file})
        return report

    def test_the_current_configuration_follows_the_decisions(self):
        report = self.run_check()
        self.assertEqual(report.errors, [])
        self.assertTrue(report.pending, "nothing is validated by a mairie yet")

    def test_a_period_not_applied_by_the_configuration_fails(self):
        self.edit("retention.yaml", 'sessions: {period: "6 months"', 'sessions: {period: "3 months"')
        self.assertIn("retention.policies.sessions is 6 months, retention.yaml decides 3 months", " ".join(self.run_check().errors))

    def test_a_backup_retention_not_applied_fails(self):
        self.edit("retention.yaml", "keep_daily: 7", "keep_daily: 30")
        self.assertIn("keep daily is 7, retention.yaml decides 30", " ".join(self.run_check().errors))

    def test_an_undeclared_external_host_fails(self):
        self.edit("subprocessors.yaml", "hosts: [smtp.resend.com, api.resend.com]", "hosts: [api.resend.com]")
        self.assertIn("external host smtp.resend.com is not a declared subprocessor", " ".join(self.run_check().errors))

    def test_technical_logs_are_at_most_one_year(self):
        self.edit("retention.yaml", 'period: "1 year"\n  maximum: "1 year"', 'period: "2 years"\n  maximum: "2 years"')
        self.assertIn("exceeds its maximum", " ".join(self.run_check().errors))

    def test_an_incomplete_register_fails(self):
        self.edit("register.yaml", "    legal_basis: public task (GDPR art. 6.1.e), management of the town hall's staff\n", "")
        self.assertIn("accounts: legal_basis is required", " ".join(self.run_check().errors))

    def test_the_legal_pages_must_show_the_decided_periods(self):
        self.edit("retention.yaml", 'connection_logs: {period: "1 year"', 'connection_logs: {period: "2 years"')
        errors = " ".join(self.run_check().errors)
        self.assertIn("global.legal.retention.connection_logs is 1 year, retention.yaml decides 2 years", errors)

    def test_the_legal_pages_must_list_the_subprocessors(self):
        self.edit("subprocessors.yaml", 'purpose_fr: "envoi des e-mails', 'purpose_fr: "envoi de tous les e-mails')
        self.assertIn("global.legal.subprocessors differ", " ".join(self.run_check().errors))


if __name__ == "__main__":
    unittest.main()
