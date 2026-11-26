"""Application denial-of-service aggregator: parsers, per-check findings, the gate."""
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "security" / "external" / "dos" / "dos.py"
EXPECTED = ROOT / "security" / "external" / "dos" / "expected.json"
FIX = ROOT / "security" / "external" / "dos" / "fixtures" / "http-burst-login"
spec = importlib.util.spec_from_file_location("dos", SCRIPT)
dos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dos)

THR = json.loads(EXPECTED.read_text())["thresholds"]


def bundle():
    return {
        "attack": json.loads((FIX / "attack-summary.json").read_text()),
        "legit": json.loads((FIX / "legit-summary.json").read_text()),
        "pods_before": json.loads((FIX / "pods-before.json").read_text()),
        "pods_after": json.loads((FIX / "pods-after.json").read_text()),
        "top": (FIX / "top-after.txt").read_text(),
        "recovery": json.loads((FIX / "recovery.json").read_text()),
    }


class Units(unittest.TestCase):
    def test_mair_1192_to_bytes(self):
        self.assertEqual(dos.to_bytes("512Mi"), 512 * 1024 ** 2)
        self.assertEqual(dos.to_bytes("1Gi"), 1024 ** 3)
        self.assertEqual(dos.to_bytes("268435456"), 268435456)
        self.assertIsNone(dos.to_bytes("200m"))
        self.assertIsNone(dos.to_bytes(None))

    def test_mair_1192_parse_top(self):
        parsed = dos.parse_top("a 10m 300Mi\nb 5m 1Gi\n")
        self.assertEqual(parsed, {"a": 300 * 1024 ** 2, "b": 1024 ** 3})


class Attack(unittest.TestCase):
    def test_mair_1192_shed_with_429_passes(self):
        out, counts = dos.attack_findings("s", bundle()["attack"], THR)
        self.assertEqual(out, [])
        self.assertEqual(counts["429"], 8700)

    def test_mair_1192_5xx_under_load_is_high(self):
        summary = copy.deepcopy(bundle()["attack"])
        summary["metrics"]["status_5xx"]["values"]["count"] = 4000
        out, _ = dos.attack_findings("s", summary, THR)
        self.assertTrue(out and out[0]["severity"] == "high" and "broke under load" in out[0]["title"])

    def test_mair_1192_no_shedding_is_medium(self):
        summary = {"metrics": {"status_2xx": {"values": {"count": 9000}}}}
        out, _ = dos.attack_findings("s", summary, THR)
        self.assertTrue(out and out[0]["severity"] == "medium" and "no 429/413" in out[0]["title"])


class Legit(unittest.TestCase):
    def test_mair_1192_fast_agent_passes(self):
        self.assertEqual(dos.legit_findings("s", bundle()["legit"], THR), [])

    def test_mair_1192_slow_agent_is_high(self):
        summary = {"metrics": {"http_req_duration": {"values": {"p(95)": 5000}}}}
        out = dos.legit_findings("s", summary, THR)
        self.assertTrue(out and out[0]["severity"] == "high" and "latency" in out[0]["title"])


class Cluster(unittest.TestCase):
    def test_mair_1192_no_restart_passes(self):
        b = bundle()
        self.assertEqual(dos.restart_findings("s", b["pods_before"], b["pods_after"]), [])

    def test_mair_1192_restart_is_high(self):
        b = bundle()
        after = copy.deepcopy(b["pods_after"])
        after["items"][0]["status"]["containerStatuses"][0]["restartCount"] = 1
        out = dos.restart_findings("s", b["pods_before"], after)
        self.assertTrue(out and out[0]["severity"] == "high" and "restarted" in out[0]["title"])

    def test_mair_1192_memory_under_limit_passes(self):
        b = bundle()
        self.assertEqual(dos.memory_findings("s", b["pods_after"], b["top"], THR), [])

    def test_mair_1192_memory_at_limit_is_high(self):
        b = bundle()
        top = "staging-core-api-1 220m 500Mi\nstaging-user-bff-1 90m 120Mi\n"
        out = dos.memory_findings("s", b["pods_after"], top, THR)
        self.assertTrue(out and out[0]["severity"] == "high" and "limit" in out[0]["title"])


class Recovery(unittest.TestCase):
    def test_mair_1192_fast_recovery_passes(self):
        self.assertEqual(dos.recovery_findings("s", {"recovered_after_seconds": 35}, THR), [])

    def test_mair_1192_no_recovery_is_high(self):
        out = dos.recovery_findings("s", {"recovered_after_seconds": None}, THR)
        self.assertTrue(out and out[0]["severity"] == "high" and "did not recover" in out[0]["title"])

    def test_mair_1192_slow_recovery_is_medium(self):
        out = dos.recovery_findings("s", {"recovered_after_seconds": 300}, THR)
        self.assertTrue(out and out[0]["severity"] == "medium" and "slow" in out[0]["title"])


class Cli(unittest.TestCase):
    def _run(self, scenario_bundle, missing_scenarios=False):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            cfg = json.loads(EXPECTED.read_text())
            cfg["scenarios"] = ["demo"] if not missing_scenarios else ["demo", "absent"]
            (tmp / "expected.json").write_text(json.dumps(cfg))
            d = tmp / "demo"
            d.mkdir()
            for name, payload in scenario_bundle.items():
                path = d / name
                path.write_text(payload if isinstance(payload, str) else json.dumps(payload))
            code = dos.main(["--expected", str(tmp / "expected.json"), "--artifacts", str(tmp)])
            report = json.loads((tmp / "report.json").read_text())
            md = (tmp / "report.md").read_text()
        return code, report, md

    def test_mair_1192_clean_scenario_passes(self):
        files = {
            "attack-summary.json": json.loads((FIX / "attack-summary.json").read_text()),
            "legit-summary.json": json.loads((FIX / "legit-summary.json").read_text()),
            "pods-before.json": json.loads((FIX / "pods-before.json").read_text()),
            "pods-after.json": json.loads((FIX / "pods-after.json").read_text()),
            "top-after.txt": (FIX / "top-after.txt").read_text(),
            "recovery.json": {"recovered_after_seconds": 30},
        }
        code, report, md = self._run(files)
        self.assertEqual(code, 0)
        self.assertEqual(report["deviations"], [])
        self.assertIn("**OK**", md)

    def test_mair_1192_broken_scenario_fails(self):
        files = {
            "attack-summary.json": {"metrics": {"status_5xx": {"values": {"count": 9000}},
                                                "status_2xx": {"values": {"count": 10}}}},
            "recovery.json": {"recovered_after_seconds": None},
        }
        code, report, md = self._run(files)
        self.assertEqual(code, 1)
        self.assertIn("**FAILED**", md)
        self.assertTrue(any("broke under load" in d["title"] for d in report["deviations"]))

    def test_mair_1192_missing_scenario_is_reported(self):
        files = {"attack-summary.json": json.loads((FIX / "attack-summary.json").read_text())}
        code, report, _ = self._run(files, missing_scenarios=True)
        self.assertEqual(code, 1)
        self.assertTrue(any("no artifacts" in d["title"] for d in report["deviations"]))


class Assets(unittest.TestCase):
    def test_mair_1192_expected_staging_and_thresholds(self):
        cfg = json.loads(EXPECTED.read_text())
        self.assertTrue(cfg["domain"].startswith("staging."))
        self.assertIn("recovery_max_seconds", cfg["thresholds"])
        self.assertTrue(cfg["scenarios"])


if __name__ == "__main__":
    unittest.main()
