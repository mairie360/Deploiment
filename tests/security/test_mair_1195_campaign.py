"""External attack campaign orchestrator: family order, per-family verdict, aggregation, exit code."""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "security" / "external" / "campaign.py"
CONFIG = ROOT / "security" / "external" / "campaign.json"
spec = importlib.util.spec_from_file_location("campaign", SCRIPT)
campaign = importlib.util.module_from_spec(spec)
spec.loader.exec_module(campaign)

CFG = json.loads(CONFIG.read_text())


def write_report(out_dir, family_key, report_file, payload):
    d = out_dir / family_key
    d.mkdir(parents=True, exist_ok=True)
    (d / report_file).write_text(json.dumps(payload))


class Config(unittest.TestCase):
    def test_mair_1195_family_order_dos_last(self):
        keys = [f["key"] for f in CFG["families"]]
        self.assertEqual(keys, ["recon", "auth", "access", "dast", "business", "supply-chain", "dos"])
        self.assertEqual(keys[-1], "dos")

    def test_mair_1195_controls_cover_e01_to_e13(self):
        ids = {c["id"] for c in CFG["controls"]}
        for n in range(1, 14):
            self.assertIn(f"E-{n:02d}", ids, f"E-{n:02d} missing")
        for c in CFG["controls"]:
            # Each control carries a short label, an honest state and either the ticket that
            # touched it or "—" for a control outside this epic's scope (E-05 host, E-06 WAF).
            self.assertTrue(c["control"] and c["state"], c)
            self.assertTrue(c["ticket"] == "—" or c["ticket"].startswith("MAIR-"), c)

    def test_mair_1195_scoped_controls_are_delivered_not_overstated(self):
        by_id = {c["id"]: c for c in CFG["controls"]}
        # Controls this epic actually delivers are marked in place; defences it only tests or
        # leaves out of scope are not claimed as done.
        self.assertIn("En place", by_id["E-08"]["state"])   # monthly reconnaissance
        self.assertIn("En place", by_id["E-09"]["state"])   # incident runbook
        self.assertIn("En place", by_id["E-11"]["state"])   # campaign orchestrator + planning
        self.assertNotIn("En place", by_id["E-06"]["state"])  # WAF: out of scope
        self.assertEqual("—", by_id["E-06"]["ticket"])

    def test_mair_1195_schedule_has_next_dates(self):
        self.assertIn("next_campaign", CFG["schedule"])
        self.assertIn("next_recon", CFG["schedule"])


class Verdict(unittest.TestCase):
    def test_mair_1195_clean_report_is_ok(self):
        fam = {"result_key": "deviations"}
        self.assertEqual(campaign.family_verdict(fam, {"deviations": []})[0], "ok")

    def test_mair_1195_findings_fail(self):
        fam = {"result_key": "deviations"}
        self.assertEqual(campaign.family_verdict(fam, {"deviations": ["x"]})[0], "failed")

    def test_mair_1195_dast_failed_flag_fails(self):
        fam = {"result_key": "findings"}
        self.assertEqual(campaign.family_verdict(fam, {"findings": [], "failed": True})[0], "failed")

    def test_mair_1195_absent_report_is_not_run(self):
        fam = {"result_key": "deviations"}
        self.assertEqual(campaign.family_verdict(fam, None)[0], "not_run")


class Aggregate(unittest.TestCase):
    def run_campaign(self, reports, **kw):
        """reports: {family_key: payload or None}. driver families 'run' by writing their report."""
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            cfg = json.loads(CONFIG.read_text())
            cfg["out_dir_name"] = "campaign"

            def fake_runner(family, report_dir):
                payload = reports.get(family["key"])
                if payload is not None:
                    report_dir.mkdir(parents=True, exist_ok=True)
                    (report_dir / family["report_file"]).write_text(json.dumps(payload))

            # Manual families' reports are pre-placed (the operator produced them).
            for fam in cfg["families"]:
                if fam["mode"] == "manual" and reports.get(fam["key"]) is not None:
                    write_report(out, fam["key"], fam["report_file"], reports[fam["key"]])

            report = campaign.run(cfg, out, skip=set(), aggregate_only=False, runner=fake_runner, **kw)
            report["date"] = "now"
            md = campaign.render_markdown(cfg, report)
        return report, md

    def test_mair_1195_all_clean_passes(self):
        clean = {"recon": {"deviations": []}, "auth": {"deviations": []}, "access": {"deviations": []},
                 "dast": {"findings": [], "failed": False}, "business": {"deviations": []},
                 "supply-chain": {"findings": []}, "dos": {"deviations": []}}
        report, md = self.run_campaign(clean, env_ok=True)
        self.assertEqual(report["deviations"], 0)
        self.assertEqual(report["missing_required"], [])
        self.assertIn("**OK**", md)
        self.assertEqual([f["status"] for f in report["families"]], ["ok"] * 7)

    def test_mair_1195_a_family_finding_fails_the_campaign(self):
        reports = {"recon": {"deviations": []}, "auth": {"deviations": ["no per-IP block"]},
                   "access": {"deviations": []}, "dast": {"findings": [], "failed": False},
                   "business": {"deviations": []}, "supply-chain": {"findings": []}, "dos": {"deviations": []}}
        report, md = self.run_campaign(reports, env_ok=True)
        self.assertEqual(report["deviations"], 1)
        self.assertIn("**FAILED**", md)
        auth = next(f for f in report["families"] if f["key"] == "auth")
        self.assertEqual(auth["status"], "failed")

    def test_mair_1195_manual_family_not_run_is_recorded(self):
        reports = {"recon": {"deviations": []}, "auth": {"deviations": []}, "access": {"deviations": []},
                   "dast": None, "business": {"deviations": []}, "supply-chain": {"findings": []},
                   "dos": None}
        report, md = self.run_campaign(reports, env_ok=True)
        dast = next(f for f in report["families"] if f["key"] == "dast")
        self.assertEqual(dast["status"], "not_run")
        self.assertIn("not run", md)

    def test_mair_1195_every_section_and_controls_in_report(self):
        clean = {k: ({"findings": []} if k in ("dast", "supply-chain") else {"deviations": []})
                 for k in ["recon", "auth", "access", "dast", "business", "supply-chain", "dos"]}
        _, md = self.run_campaign(clean, env_ok=True)
        for fam in CFG["families"]:
            self.assertIn(f"### {fam['label']}", md)
        self.assertIn("## Controls E-01 → E-13", md)
        self.assertIn("E-01", md)
        self.assertIn("## Next dates", md)


class Cli(unittest.TestCase):
    def test_mair_1195_cli_aggregate_only_fails_on_missing_required(self):
        # A fresh out-dir with no reports, aggregate-only: driver families have no report -> not_run.
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {}, clear=True):
            code = campaign.main(["--out-dir", tmp, "--aggregate-only"])
            report = json.loads((Path(tmp) / "campaign-report.json").read_text())
        # None of the families are marked required in the config, so not_run does not fail the run,
        # but every family is not_run and the report is written.
        self.assertEqual(code, 0)
        self.assertTrue(all(f["status"] == "not_run" for f in report["families"]))

    def test_mair_1195_cli_writes_both_reports(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {}, clear=True):
            campaign.main(["--out-dir", tmp, "--aggregate-only"])
            self.assertTrue((Path(tmp) / "campaign-report.md").is_file())
            self.assertTrue((Path(tmp) / "campaign-report.json").is_file())


if __name__ == "__main__":
    unittest.main()
