"""Global RGAA rate of the prod fronts, prod gate and accessible release note."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "scripts" / "rgaa-global.py"
spec = importlib.util.spec_from_file_location("rgaa_global", SCRIPT)
rgaa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rgaa)

VALUES = """
Fronts:
  instances:
    login-front:
      enabled: true
      image: { repository: ghcr.io/mairie360/login-front, tag: "0.5.0" }
    calendar-front:
      enabled: true
      image: { repository: ghcr.io/mairie360/calendar-front, tag: "0.6.0" }
    project-front:
      enabled: true
      image: { repository: ghcr.io/mairie360/projects-front, tag: "1.2.0" }
    message-front:
      enabled: false
      image: { repository: ghcr.io/mairie360/message-front, tag: "0.6.0" }
"""


def crit(cid, status, *pages):
    return {"id": cid, "status": status,
            "failures": [{"state": p, "check": "axe:color-contrast", "target": ".label-" + p, "message": "m"}
                         for p in pages]}


def report(*criteria, value=None):
    return {"rate": {"value": value}, "criteria": list(criteria)}


LOGIN = report(crit("1.1", "validated"), crit("3.2", "invalidated", "login"), crit("8.5", "validated"),
               crit("11.1", "validated"), value=75)
CALENDAR = report(crit("1.1", "validated"), crit("3.2", "validated"), crit("8.5", "to review"),
                  crit("11.1", "invalidated", "month", "week"), crit("12.6", "validated"), value=60)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.values = self.dir / "prod.yaml"
        self.values.write_text(VALUES, encoding="utf-8")
        self.reports = self.dir / "reports"
        self.reports.mkdir()

    def put(self, repo, data):
        (self.reports / (repo + ".json")).write_text(data if isinstance(data, str) else json.dumps(data), encoding="utf-8")

    def run_script(self, *args, env=None):
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True,
                              env={**os.environ, **(env or {})})


class Aggregate(Fixture):
    def test_MAIR_322_a_criterion_invalid_on_one_front_is_invalid_for_the_platform(self):
        fronts = [("login-front", "Login_Web_Service", "Connexion", "0.5.0", LOGIN),
                  ("calendar-front", "Calendars_Web_Service", "Agenda", "0.6.0", CALENDAR)]
        result = rgaa.aggregate(fronts)
        self.assertEqual(result["statuses"], {"1.1": "validated", "3.2": "invalidated", "8.5": "to_review",
                                              "11.1": "invalidated", "12.6": "validated"})
        # validated 2 (1.1, 12.6) / decided 4 = 50 %
        self.assertEqual((result["validated"], result["invalidated"], result["to_review"], result["rate"]), (2, 2, 1, 50.0))
        self.assertEqual([label for label, _ in result["failures"]["3.2"]], ["Connexion"])

    def test_MAIR_322_the_rate_is_rounded_down(self):
        r = report(crit("1.1", "validated"), crit("1.2", "validated"), crit("3.2", "invalidated", "p"))
        self.assertEqual(rgaa.aggregate([("x", "X", "X", "1.0.0", r)])["rate"], 66.6)

    def test_MAIR_322_legal_status_thresholds(self):
        self.assertEqual([rgaa.legal_status(r) for r in (100, 99.9, 50, 49.9, None)],
                         ["totalement conforme", "partiellement conforme", "partiellement conforme",
                          "non conforme", "non évalué"])


class Pins(Fixture):
    def test_MAIR_322_reads_the_enabled_fronts_and_their_repository(self):
        pins = rgaa.prod_pins(str(self.values))
        self.assertEqual([(repo, tag) for _, repo, _, tag in pins],
                         [("Calendars_Web_Service", "0.6.0"), ("Login_Web_Service", "0.5.0"),
                          ("Projects_Web_Service", "1.2.0")])

    def test_MAIR_322_refuses_an_unknown_front_or_a_moving_tag(self):
        for text in (VALUES.replace("projects-front", "new-front"), VALUES.replace('"1.2.0"', '"staging-abc1234"')):
            with self.subTest(text=text[-80:]):
                self.values.write_text(text, encoding="utf-8")
                proc = self.run_script("gate", "--values", str(self.values), "--reports", str(self.reports))
                self.assertEqual(proc.returncode, 2, proc.stdout)

    def test_MAIR_322_every_prod_front_is_known(self):
        pins = rgaa.prod_pins(str(ROOT / "clusters" / "_base" / "prod.yaml"))
        self.assertEqual(len(pins), 8)


class Gate(Fixture):
    def test_MAIR_322_blocks_below_the_minimum_and_lists_the_failing_criteria(self):
        self.put("Login_Web_Service", LOGIN)
        self.put("Calendars_Web_Service", CALENDAR)
        summary = self.dir / "summary.md"
        proc = self.run_script("gate", "--values", str(self.values), "--reports", str(self.reports),
                               "--min", "60", "--summary", str(summary))
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("::error title=RGAA global::platform rate 50.0 % below the 60.0 % minimum; failing criteria: 3.2, 11.1", proc.stdout)
        text = summary.read_text(encoding="utf-8")
        self.assertIn("**50.0 %**", text)
        self.assertIn("**porte refusée**", text)
        self.assertIn("- **Critère 11.1**\n  - Agenda : 2 élément(s) sur `month`, `week`", text)
        self.assertIn("    - `.label-login`", text)
        # Projects has no report: listed and left out.
        self.assertIn("Sans rapport RGAA (exclus du taux) : Projects_Web_Service `v1.2.0`", text)
        self.assertIn("::warning title=RGAA global::Projects_Web_Service v1.2.0 has no rgaa-report.json", proc.stdout)

    def test_MAIR_322_passes_at_the_minimum(self):
        self.put("Login_Web_Service", LOGIN)
        self.put("Calendars_Web_Service", CALENDAR)
        proc = self.run_script("gate", "--values", str(self.values), "--reports", str(self.reports))
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("porte passée", proc.stdout)

    def test_MAIR_322_no_report_yet_warns_and_passes(self):
        self.put("Login_Web_Service", "{broken")
        proc = self.run_script("gate", "--values", str(self.values), "--reports", str(self.reports))
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("nothing to gate", proc.stdout)


class GitHubReleases(Fixture):
    """The reports come from `gh release download v<tag> --pattern rgaa-report.json`."""

    def fake_gh(self, body):
        bin_dir = self.dir / "bin"
        bin_dir.mkdir(exist_ok=True)
        gh = bin_dir / "gh"
        gh.write_text("#!/usr/bin/env bash\necho \"$*\" >> \"$GH_LOG\"\n" + body, encoding="utf-8")
        gh.chmod(0o755)
        return {"PATH": "{}:{}".format(bin_dir, os.environ["PATH"]), "GH_LOG": str(self.dir / "gh.log")}

    def test_MAIR_322_downloads_the_asset_of_each_pinned_release(self):
        login = json.dumps(LOGIN).replace("'", "'\\''")
        env = self.fake_gh("""args="$*"; out=""
while [ $# -gt 0 ]; do [ "$1" = --output ] && out=$2; shift; done
if [[ $args == *Login_Web_Service* ]]; then printf '%s' '""" + login + """' > "$out"; exit 0; fi
echo "no assets to download" >&2; exit 1
""")
        proc = self.run_script("gate", "--values", str(self.values), env=env)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        calls = (self.dir / "gh.log").read_text().splitlines()
        self.assertTrue(any(c.startswith("release download v0.5.0 --repo mairie360/Login_Web_Service --pattern rgaa-report.json")
                            for c in calls), calls)
        self.assertIn("**75.0 %**", proc.stdout)

    def test_MAIR_322_an_api_error_is_not_a_missing_report(self):
        env = self.fake_gh('echo "HTTP 401: Bad credentials" >&2; exit 1\n')
        proc = self.run_script("gate", "--values", str(self.values), env=env)
        self.assertEqual(proc.returncode, 2, proc.stdout)


class Note(Fixture):
    def setUp(self):
        super().setUp()
        self.releases = self.dir / "releases"
        self.releases.mkdir()
        (self.releases / "1.0.0.yaml").write_text('version: "1.0.0"\ncreated: "2026-11-18T10:00:00Z"\nrepos: {}\n')
        self.put("Login_Web_Service", LOGIN)
        self.put("Calendars_Web_Service", CALENDAR)

    def test_MAIR_322_note_gives_the_rate_the_status_and_the_failing_criteria(self):
        out = self.dir / "note.md"
        proc = self.run_script("note", "1.0.0", "--values", str(self.values), "--reports", str(self.reports),
                               "--releases", str(self.releases), "--out", str(out))
        self.assertEqual(proc.returncode, 0, proc.stdout)
        text = out.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# Mairie 360 version 1.0.0 : accessibilité\n"))
        self.assertIn("Sur les 4 critères du RGAA vérifiés automatiquement, 2 sont respectés", text)
        self.assertIn("soit un taux de 50.0 %", text)
        self.assertIn("**partiellement conforme**", text)
        self.assertIn("| 3.2 | Connexion | 1 |", text)
        self.assertIn("| 11.1 | Agenda | 2 |", text)
        self.assertIn("| Projets | 1.2.0 | non mesuré |", text)
        self.assertEqual(rgaa.check_note(text), [])

    def test_MAIR_322_missing_manifest(self):
        proc = self.run_script("note", "9.9.9", "--values", str(self.values), "--reports", str(self.reports),
                               "--releases", str(self.releases))
        self.assertEqual(proc.returncode, 2)

    def test_MAIR_322_the_note_check_catches_inaccessible_markdown(self):
        bad = ("# A\n\n### Skipped level\n\nSee [ici](https://x.example).\n\n✅ ok\n\n"
               "| a | b |\n| c | d |\n\n# Second title\n")
        problems = "\n".join(rgaa.check_note(bad))
        for expected in ("heading level 3 after level 1", "link text does not say where it goes", "emoji",
                         "table without a header row", "exactly one level-1 heading, found 2"):
            with self.subTest(expected=expected):
                self.assertIn(expected, problems)


class Wiring(unittest.TestCase):
    def setUp(self):
        self.text = (ROOT / ".github" / "workflows" / "promote.yaml").read_text(encoding="utf-8")

    def job(self, name):
        start = self.text.index("\n  {}:\n".format(name))
        nxt = re.search(r"\n  [a-z][a-z0-9_-]*:\n", self.text[start + 1:])
        return self.text[start:start + 1 + nxt.start()] if nxt else self.text[start:]

    def test_MAIR_322_prod_promotion_runs_the_gate_on_the_promoted_commit(self):
        job = self.job("rgaa-global")
        self.assertIn("if: inputs.target == 'prod' && !inputs.rollback && needs.resolve.outputs.changed == 'true'", job)
        self.assertIn("ref: ${{ needs.resolve.outputs.promoted }}", job)
        self.assertIn("./scripts/rgaa-global.py gate --values clusters/_base/prod.yaml", job)
        self.assertNotIn("environment:", job)

    def test_MAIR_322_a_failed_gate_keeps_prod_where_it_is(self):
        promote = self.job("promote")
        self.assertIn("rgaa-global", re.search(r"needs: \[(.+)\]", promote).group(1))
        self.assertIn("&& needs.rgaa-global.result != 'failure'", promote)

    def test_MAIR_322_the_note_workflow_publishes_a_release_and_no_commit(self):
        text = (ROOT / ".github" / "workflows" / "release-note.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("./scripts/rgaa-global.py note", text)
        self.assertIn('tag="platform-v$VERSION"', text)
        self.assertNotIn("git push", text)
        self.assertNotIn("git commit", text)


if __name__ == "__main__":
    unittest.main()


class Mair1204Exception(unittest.TestCase):
    """MAIR-1204: the first full prod release measured 37.5 %; the user accepted it as an exception of that
    release. The minimum stays 50 % unless a promotion lowers it with a reason."""

    def setUp(self):
        self.text = (ROOT / ".github" / "workflows" / "promote.yaml").read_text(encoding="utf-8")
        step = self.text.split("- name: Global RGAA rate of the prod fronts", 1)[1]
        script = step.split("run: |\n", 1)[1]
        lines = []
        for line in script.splitlines():
            if line.strip() and not line.startswith("          "):
                break
            lines.append(line[10:])
        self.script = "\n".join(lines) + "\n"
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / "scripts").mkdir()
        fake = root / "scripts" / "rgaa-global.py"
        fake.write_text('#!/usr/bin/env bash\necho "gate $*" > "$CALLS"\n', encoding="utf-8")
        fake.chmod(0o755)
        self.root = root

    def run_step(self, min_rate, exception=""):
        summary = self.root / "summary.md"
        calls = self.root / "calls"
        for f in (summary, calls):
            f.write_text("", encoding="utf-8")
        env = dict(os.environ, MIN_RATE=min_rate, EXCEPTION=exception, GITHUB_STEP_SUMMARY=str(summary),
                   CALLS=str(calls))
        result = subprocess.run(["bash", "-e", "-c", self.script], cwd=self.root, env=env,
                                capture_output=True, text=True)
        return result, calls.read_text(encoding="utf-8"), summary.read_text(encoding="utf-8")

    def test_MAIR_1204_the_minimum_defaults_to_50(self):
        inputs = self.text.split("rgaa_min_rate:", 1)[1].split("rgaa_exception:", 1)[0]
        self.assertIn('default: "50"', inputs)
        result, calls, _ = self.run_step("50")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('--min 50', calls)

    def test_MAIR_1204_a_lower_minimum_without_a_reason_is_refused(self):
        result, calls, _ = self.run_step("37", "  ")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("needs rgaa_exception", result.stdout)
        self.assertEqual(calls, "")

    def test_MAIR_1204_a_lower_minimum_with_its_reason_is_traced_and_used(self):
        result, calls, summary = self.run_step("37", "first full release, fixes in MAIR-1300")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--min 37", calls)
        self.assertIn("::warning title=RGAA global::minimum lowered to 37 %", result.stdout)
        self.assertIn("first full release, fixes in MAIR-1300", summary)

    def test_MAIR_1204_an_invalid_minimum_is_refused(self):
        for value in ("abc", "101", "-5", "50; rm -rf /"):
            with self.subTest(value=value):
                result, calls, _ = self.run_step(value, "reason")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, "")
