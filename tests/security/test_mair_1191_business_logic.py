"""Business-logic and no-session abuse scenarios: sequence verdicts, e-mail and alert caps."""
import importlib.util
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "security" / "external" / "business" / "business.py"
EXPECTED = ROOT / "security" / "external" / "business" / "expected.json"
TEMPLATE = ROOT / "security" / "external" / "business" / "scenarios" / "public.json.template"
spec = importlib.util.spec_from_file_location("business", SCRIPT)
business = importlib.util.module_from_spec(spec)
spec.loader.exec_module(business)

PASSWORD = "Correct-Horse-Battery"
KNOWN = {"attack.user@example.invalid", "attack.responsable@example.invalid", "attack.admin@example.invalid"}


class FakeServer(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, status, payload, cookies=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for c in cookies or []:
            self.send_header("Set-Cookie", c)
        data = json.dumps(payload).encode()
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n) or b"{}")

    def session(self):
        c = self.headers.get("Cookie", "")
        return c.split("accessToken=", 1)[1].split(";", 1)[0] if "accessToken=" in c else ""

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        srv = self.server
        p = self.path
        if p == "/api/auth/login":
            b = self.body()
            if b.get("email") in KNOWN and b.get("password") == PASSWORD:
                return self._json(200, {"ok": True}, cookies=[f"accessToken=sess-{b['email']}"])
            return self._json(401, {"code": "invalid"})
        if p == "/api/auth/forgot-password":
            srv.forgot_calls += 1
            if srv.forgot_calls > srv.forgot_cap:
                return self._json(429, {"code": "rate_limited"})
            return self._json(200, {"message": "ok"})
        if p == "/api/security-alert":
            srv.alert_calls += 1
            if srv.alert_calls > srv.alert_cap:
                return self._json(429, {"code": "rate_limited"})
            return self._json(200, {"message": "ok"})
        if p == "/calendar/events" and method == "POST":
            b = self.body()
            if b.get("endDate") and b.get("date") and b["endDate"] < b["date"]:
                return self._json(422, {"code": "invalid_dates"}) if not srv.accept_bad_dates else self._json(201, {"id": "evt-bad"})
            srv.seq += 1
            eid = f"evt-{srv.seq}"
            srv.events[eid] = True
            return self._json(201, {"id": eid})
        if p.startswith("/calendar/events/"):
            eid = p.rsplit("/", 1)[1]
            alive = srv.events.get(eid, False)
            if method == "DELETE":
                if alive:
                    srv.events[eid] = False
                    return self._json(204, {})
                return self._json(404, {"code": "not_found"}) if not srv.deleted_still_acts else self._json(204, {})
            if alive or srv.deleted_still_acts:
                return self._json(200, {"id": eid})
            return self._json(404, {"code": "not_found"})
        self._json(404, {"code": "not_found"})


def make_server(**knobs):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeServer)
    srv.events, srv.seq = {}, 0
    srv.forgot_calls = srv.alert_calls = 0
    srv.forgot_cap, srv.alert_cap = 5, 5
    srv.accept_bad_dates = srv.deleted_still_acts = False
    for k, v in knobs.items():
        setattr(srv, k, v)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def cfg_and_patch(srv):
    cfg = json.loads(EXPECTED.read_text())
    cfg["rate_per_second"] = 1000
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    return cfg, mock.patch.object(business, "front_url", lambda c, front, path: base + path)


class Sequences(unittest.TestCase):
    def limiter(self):
        return business.RateLimiter(1000)

    def test_mair_1191_secure_server_has_no_finding(self):
        srv = make_server()
        cfg, patch = cfg_and_patch(srv)
        with patch, mock.patch.dict(os.environ, {"AUTH_TEST_PASSWORD": PASSWORD}):
            sessions = business.sign_in(cfg, self.limiter())
            report = business.run(cfg, self.limiter(), sessions, skip=set())
        self.assertEqual(report["deviations"], [], report["deviations"])

    def test_mair_1191_acting_on_deleted_event_is_a_finding(self):
        srv = make_server(deleted_still_acts=True)
        cfg, patch = cfg_and_patch(srv)
        seq = next(s for s in cfg["sequences"] if "deleted" in s["name"])
        with patch, mock.patch.dict(os.environ, {"AUTH_TEST_PASSWORD": PASSWORD}):
            sessions = business.sign_in(cfg, self.limiter())
            findings, _ = business.run_sequence(cfg, self.limiter(), sessions, seq)
        self.assertTrue(findings)
        self.assertTrue(any("was allowed" in f for f in findings))

    def test_mair_1191_inconsistent_dates_accepted_is_a_finding(self):
        srv = make_server(accept_bad_dates=True)
        cfg, patch = cfg_and_patch(srv)
        seq = next(s for s in cfg["sequences"] if "ending before" in s["name"])
        with patch, mock.patch.dict(os.environ, {"AUTH_TEST_PASSWORD": PASSWORD}):
            sessions = business.sign_in(cfg, self.limiter())
            findings, _ = business.run_sequence(cfg, self.limiter(), sessions, seq)
        self.assertTrue(any("was allowed" in f for f in findings))


class Caps(unittest.TestCase):
    def limiter(self):
        return business.RateLimiter(1000)

    def test_mair_1191_forgot_password_cap_observed(self):
        srv = make_server(forgot_cap=5)
        cfg, patch = cfg_and_patch(srv)
        with patch:
            findings, obs = business.email_abuse(cfg, self.limiter())
        self.assertEqual(findings, [])
        self.assertTrue(all(o["capped_at"] is not None for o in obs))

    def test_mair_1191_no_email_cap_is_a_finding(self):
        srv = make_server(forgot_cap=10_000)
        cfg, patch = cfg_and_patch(srv)
        with patch:
            findings, _ = business.email_abuse(cfg, self.limiter())
        self.assertTrue(findings and all("no cap" in f for f in findings))

    def test_mair_1191_alert_cap_observed_and_missing(self):
        srv = make_server(alert_cap=5)
        cfg, patch = cfg_and_patch(srv)
        with patch:
            self.assertEqual(business.alert_abuse(cfg, self.limiter())[0], [])
        srv2 = make_server(alert_cap=10_000)
        cfg2, patch2 = cfg_and_patch(srv2)
        with patch2:
            findings, _ = business.alert_abuse(cfg2, self.limiter())
        self.assertTrue(findings and "spammed" in findings[0])


class Cli(unittest.TestCase):
    def test_mair_1191_session_journeys_need_the_password(self):
        with mock.patch.dict(os.environ, {}, clear=True), tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(business.main(["--out-dir", tmp]), 2)

    def test_mair_1191_cli_writes_report_and_fails_on_finding(self):
        srv = make_server(forgot_cap=10_000, alert_cap=10_000)
        cfg, patch = cfg_and_patch(srv)
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = Path(tmp) / "e.json"
            cfg_path.write_text(json.dumps(cfg))
            with patch:
                code = business.main(["--expected", str(cfg_path), "--out-dir", tmp, "--skip", "sequences"])
            report = json.loads((Path(tmp) / "report.json").read_text())
            self.assertIn("FAILED", (Path(tmp) / "report.md").read_text())
        self.assertEqual(code, 1)
        self.assertTrue(any("no cap" in d for d in report["deviations"]))


class Assets(unittest.TestCase):
    def test_mair_1191_staging_test_accounts_and_cap(self):
        cfg = json.loads(EXPECTED.read_text())
        self.assertTrue(cfg["domain"].startswith("staging."))
        for email in cfg["accounts"].values():
            self.assertTrue(email.endswith("@example.invalid"))
        self.assertLessEqual(cfg["rate_per_second"], 5)

    def test_mair_1191_public_template_is_empty_and_valid(self):
        doc = json.loads(TEMPLATE.read_text())
        self.assertEqual(doc["sequences"], [])
        self.assertIn("no_session_abuse", doc)


if __name__ == "__main__":
    unittest.main()
