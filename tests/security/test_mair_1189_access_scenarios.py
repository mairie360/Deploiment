"""Access-control attack scenarios: elevation and IDOR verdicts against a fake multi-front server."""
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
SCRIPT = ROOT / "security" / "external" / "access" / "access.py"
EXPECTED = ROOT / "security" / "external" / "access" / "expected.json"
spec = importlib.util.spec_from_file_location("access", SCRIPT)
access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(access)

PASSWORD = "Correct-Horse-Battery"
KNOWN = {"attack.guest@example.invalid", "attack.user@example.invalid", "attack.user.b@example.invalid",
         "attack.responsable@example.invalid", "attack.maire@example.invalid", "attack.admin@example.invalid"}


class FakeFronts(BaseHTTPRequestHandler):
    """Login + admin + calendar fronts on one port; per-test knobs on the server."""

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

    def session(self):
        cookie = self.headers.get("Cookie", "")
        return cookie.split("accessToken=", 1)[1].split(";", 1)[0] if "accessToken=" in cookie else ""

    def read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length) or b"{}")

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
        path = self.path
        if path == "/api/auth/login":
            body = self.read_body()
            if body.get("email") in KNOWN and body.get("password") == PASSWORD:
                return self._json(200, {"ok": True}, cookies=[f"accessToken=sess-{body['email']}"])
            return self._json(401, {"code": "invalid"})
        sess = self.session()
        if path.startswith("/admin/"):
            # Admin ops answer only to the admin account, unless the insecure knob is on.
            if sess.endswith("admin@example.invalid") or srv.guest_reaches_admin:
                return self._json(200, {"ok": True})
            return self._json(403, {"code": "forbidden"})
        if path == "/calendar/events" and method == "POST":
            body = self.read_body()
            srv.event_seq += 1
            eid = f"evt-{srv.event_seq}"
            srv.events[eid] = {"owner": sess, "title": body.get("title", "")}
            return self._json(201, {"id": eid, "title": body.get("title", "")})
        if path.startswith("/calendar/events/"):
            eid = path.rsplit("/", 1)[1]
            event = srv.events.get(eid)
            if not event:
                return self._json(404, {"code": "not_found"})
            if sess == event["owner"] or srv.idor_open:
                return self._json(200, {"id": eid, "title": event["title"]})
            return self._json(403, {"code": "forbidden"})
        self._json(404, {"code": "not_found"})


def make_server(**knobs):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeFronts)
    srv.events, srv.event_seq = {}, 0
    srv.guest_reaches_admin = False
    srv.idor_open = False
    for k, v in knobs.items():
        setattr(srv, k, v)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def cfg_and_patch(srv):
    """Load expected.json and route every front to the fake server."""
    cfg = json.loads(EXPECTED.read_text())
    cfg["rate_per_second"] = 1000
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    patch = mock.patch.object(access, "front_url", lambda c, front, path: base + path)
    return cfg, patch


class Elevation(unittest.TestCase):
    def test_mair_1189_guest_refused_on_admin_has_no_finding(self):
        srv = make_server()
        cfg, patch = cfg_and_patch(srv)
        limiter = access.RateLimiter(1000)
        with patch:
            sessions = access.sign_in_all(cfg, limiter, PASSWORD)
            findings, obs = access.elevation(cfg, limiter, sessions)
        self.assertEqual(findings, [], findings)
        self.assertTrue(all(o["status"] == 403 for o in obs))

    def test_mair_1189_guest_reaching_admin_is_a_finding(self):
        srv = make_server(guest_reaches_admin=True)
        cfg, patch = cfg_and_patch(srv)
        limiter = access.RateLimiter(1000)
        with patch:
            sessions = access.sign_in_all(cfg, limiter, PASSWORD)
            findings, _ = access.elevation(cfg, limiter, sessions)
        self.assertEqual(len(findings), len(cfg["elevation"]["probes"]))
        self.assertTrue(all("reaches the admin operation" in f for f in findings))


class Idor(unittest.TestCase):
    def test_mair_1189_owner_only_has_no_finding(self):
        srv = make_server()
        cfg, patch = cfg_and_patch(srv)
        limiter = access.RateLimiter(1000)
        with patch:
            sessions = access.sign_in_all(cfg, limiter, PASSWORD)
            findings, obs = access.idor(cfg, limiter, sessions)
        self.assertEqual(findings, [], findings)
        access_ops = [o for o in obs if o.get("op")]
        self.assertTrue(access_ops and all(o["status"] == 403 for o in access_ops))

    def test_mair_1189_cross_account_access_is_a_finding_with_leak(self):
        srv = make_server(idor_open=True)
        cfg, patch = cfg_and_patch(srv)
        limiter = access.RateLimiter(1000)
        with patch:
            sessions = access.sign_in_all(cfg, limiter, PASSWORD)
            findings, obs = access.idor(cfg, limiter, sessions)
        self.assertTrue(findings)
        self.assertTrue(any("carries its data" in f for f in findings))
        self.assertTrue(any(o.get("leaked") for o in obs))


class Run(unittest.TestCase):
    def test_mair_1189_requires_the_password(self):
        with mock.patch.dict(os.environ, {}, clear=True), tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(access.main(["--out-dir", tmp]), 2)

    def test_mair_1189_cli_writes_report_and_exit_code(self):
        srv = make_server(idor_open=True)
        cfg, patch = cfg_and_patch(srv)
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = Path(tmp) / "e.json"
            cfg_path.write_text(json.dumps(cfg))
            with patch, mock.patch.dict(os.environ, {"AUTH_TEST_PASSWORD": PASSWORD}):
                code = access.main(["--expected", str(cfg_path), "--out-dir", tmp, "--skip", "elevation"])
            report = json.loads((Path(tmp) / "report.json").read_text())
            self.assertIn("FAILED", (Path(tmp) / "report.md").read_text())
        self.assertEqual(code, 1)
        self.assertEqual(report["scenarios"]["elevation"], {"skipped": True})
        self.assertIn("idor", [d.split(":")[0] for d in report["deviations"]])


class Expected(unittest.TestCase):
    def test_mair_1189_staging_only_test_accounts_and_cap(self):
        cfg = json.loads(EXPECTED.read_text())
        self.assertTrue(cfg["domain"].startswith("staging."))
        for email in cfg["accounts"].values():
            self.assertTrue(email.endswith("@example.invalid"))
        self.assertLessEqual(cfg["rate_per_second"], 5)
        self.assertEqual(cfg["elevation"]["role"], "guest")


if __name__ == "__main__":
    unittest.main()
