"""Authentication attack scenarios: JWT forging, verdicts against a fake Login front."""
import base64
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
SCRIPT = ROOT / "security" / "external" / "auth" / "auth.py"
EXPECTED = ROOT / "security" / "external" / "auth" / "expected.json"
spec = importlib.util.spec_from_file_location("auth", SCRIPT)
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)

PASSWORD = "Correct-Horse-Battery"


class FakeFront(BaseHTTPRequestHandler):
    """A Login front that behaves well by default; per-test knobs live on the server."""

    def log_message(self, *args):
        pass

    def _json(self, status, payload, cookies=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for raw in cookies or []:
            self.send_header("Set-Cookie", raw)
        body = json.dumps(payload).encode()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/session/me":
            cookie = self.headers.get("Cookie", "")
            token = cookie.split("accessToken=", 1)[1].split(";", 1)[0] if "accessToken=" in cookie else ""
            if self.server.accept_any_token and token:
                return self._json(200, {"id": 1, "role": "Admin"})
            return self._json(401, {"code": "unauthorized"})
        self._json(404, {"code": "not_found"})

    def read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_POST(self):
        srv = self.server
        body = self.read_body()
        if self.path == "/api/auth/login":
            srv.login_calls += 1
            email = body.get("email")
            srv.account_calls[email] = srv.account_calls.get(email, 0) + 1
            known = email in srv.known_accounts
            if srv.lock_everything or (known and srv.account_calls[email] > srv.account_max) \
                    or srv.login_calls > srv.ip_max:
                return self._json(429, {"code": "rate_limited"})
            if known and body.get("password") == PASSWORD:
                return self._json(200, {"ok": True}, cookies=["refreshToken=rt-" + body["email"]])
            # Uniform wrong-credentials answer, same for known and unknown.
            return self._json(401, {"code": "invalid_credentials", "message": "Invalid e-mail or password"})
        if self.path == "/api/auth/forgot-password":
            payload = {"message": "If the account exists, an e-mail was sent"}
            if srv.reflect_host:
                payload["link"] = f"https://{self.headers.get('Host')}/reset"
            return self._json(200, payload)
        if self.path == "/api/auth/login/2fa":
            srv.twofa_calls += 1
            if srv.twofa_calls > srv.account_max:
                return self._json(429, {"code": "rate_limited"})
            return self._json(401, {"code": "invalid_code"})
        if self.path == "/api/auth/reset-password":
            if srv.accept_any_reset:
                return self._json(200, {"ok": True})
            return self._json(401, {"code": "invalid_token"})
        if self.path == "/api/auth/refresh":
            token = body.get("refresh_token")
            used = token in srv.used_refresh
            srv.used_refresh.add(token)
            if used and not srv.allow_replay:
                return self._json(409, {"code": "refresh_replayed"})
            return self._json(200, {"ok": True})
        self._json(404, {"code": "not_found"})


def make_server(**knobs):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeFront)
    srv.known_accounts = {"attack.user@example.invalid", "attack.user.b@example.invalid",
                          "attack.user.c@example.invalid"}
    srv.account_max, srv.ip_max = 10, 30
    srv.login_calls = srv.twofa_calls = 0
    srv.account_calls = {}
    srv.used_refresh = set()
    srv.lock_everything = srv.accept_any_token = srv.accept_any_reset = False
    srv.reflect_host = srv.allow_replay = False
    for k, v in knobs.items():
        setattr(srv, k, v)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def cfg_for(srv):
    cfg = json.loads(EXPECTED.read_text())
    cfg["base_url"] = f"http://127.0.0.1:{srv.server_address[1]}"
    cfg["rate_per_second"] = 1000
    return cfg


class Forging(unittest.TestCase):
    def test_mair_1188_alg_none_token(self):
        token = auth.forge_jwt({"sub": "1"}, alg="none")
        header = json.loads(base64.urlsafe_b64decode(token.split(".")[0] + "=="))
        self.assertEqual(header["alg"], "none")
        self.assertTrue(token.endswith("."))

    def test_mair_1188_hs256_token_verifies_with_its_secret(self):
        import hashlib
        import hmac
        token = auth.forge_jwt({"sub": "1"}, alg="HS256", secret="changeme")
        signing_input, _, sig = token.rpartition(".")
        expected = auth.b64url(hmac.new(b"changeme", signing_input.encode(), hashlib.sha256).digest())
        self.assertEqual(sig, expected)

    def test_mair_1188_tamper_changes_only_the_signature(self):
        token = auth.forge_jwt({"sub": "1"}, alg="HS256", secret="x")
        bad = auth.tamper(token)
        self.assertEqual(token.rsplit(".", 1)[0], bad.rsplit(".", 1)[0])
        self.assertNotEqual(token, bad)


class Scenarios(unittest.TestCase):
    def limiter(self):
        return auth.RateLimiter(1000)

    def test_mair_1188_secure_front_has_no_finding(self):
        srv = make_server()
        with mock.patch.dict(os.environ, {"AUTH_TEST_PASSWORD": PASSWORD}):
            report = auth.run(cfg_for(srv), skip=set())
        self.assertEqual(report["deviations"], [], report["deviations"])

    def test_mair_1188_no_lockout_is_a_finding(self):
        srv = make_server(account_max=10_000, ip_max=10_000)
        findings, _ = auth.brute_force(cfg_for(srv), self.limiter())
        self.assertTrue(any("per-account block" in f for f in findings))
        self.assertTrue(any("per-IP block" in f for f in findings))

    def test_mair_1188_global_lockout_is_a_finding(self):
        srv = make_server(lock_everything=True)
        with mock.patch.dict(os.environ, {"AUTH_TEST_PASSWORD": PASSWORD}):
            findings, obs = auth.brute_force(cfg_for(srv), self.limiter())
        self.assertTrue(any("instance-wide" in f for f in findings))
        self.assertEqual(obs["other_account_login_status"], 429)

    def test_mair_1188_forged_token_accepted_is_a_finding(self):
        srv = make_server(accept_any_token=True)
        findings, obs = auth.tokens(cfg_for(srv), self.limiter())
        self.assertTrue(any("forged session token" in f for f in findings))
        self.assertIn("alg none", obs["forged_accepted"])

    def test_mair_1188_refresh_replay_is_a_finding(self):
        srv = make_server(allow_replay=True)
        with mock.patch.dict(os.environ, {"AUTH_TEST_PASSWORD": PASSWORD}):
            findings, obs = auth.tokens(cfg_for(srv), self.limiter())
        self.assertTrue(any("accepted twice" in f for f in findings))
        self.assertEqual(obs["refresh_replay"]["second"], 200)

    def test_mair_1188_reset_token_accepted_is_a_finding(self):
        srv = make_server(accept_any_reset=True)
        findings, _ = auth.password_reset(cfg_for(srv), self.limiter())
        self.assertTrue(any("forged reset token" in f for f in findings))
        self.assertTrue(any("random reset token" in f for f in findings))

    def test_mair_1188_host_reflection_is_a_finding(self):
        srv = make_server(reflect_host=True)
        findings, _ = auth.password_reset(cfg_for(srv), self.limiter())
        self.assertTrue(any("attacker Host" in f for f in findings))

    def test_mair_1188_twofa_not_rate_limited_is_a_finding(self):
        srv = make_server(account_max=10_000)
        findings, obs = auth.second_factor(cfg_for(srv), self.limiter())
        self.assertTrue(any("not rate-limited" in f for f in findings))

    def test_mair_1188_partial_token_session_access_is_a_finding(self):
        srv = make_server(accept_any_token=True)
        findings, obs = auth.second_factor(cfg_for(srv), self.limiter())
        self.assertEqual(obs["partial_token_session_status"], 200)
        self.assertTrue(any("session route" in f for f in findings))

    def test_mair_1188_enumeration_by_status_is_a_finding(self):
        # account_max low so a known account hits 429 while the unknown keeps 401.
        srv = make_server(account_max=1, ip_max=10_000)
        findings, _ = auth.account_enumeration(cfg_for(srv), self.limiter())
        self.assertTrue(any("status differs" in f for f in findings))


class Expected(unittest.TestCase):
    def test_mair_1188_targets_staging_with_test_accounts(self):
        cfg = json.loads(EXPECTED.read_text())
        self.assertIn("staging", cfg["base_url"])
        for role in ("primary", "secondary", "refresh", "unknown"):
            self.assertTrue(cfg["accounts"][role].endswith("@example.invalid"))
        self.assertLessEqual(cfg["rate_per_second"], 5)

    def test_mair_1188_cli_writes_report_and_exit_code(self):
        srv = make_server(accept_any_reset=True)
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = Path(tmp) / "e.json"
            cfg_path.write_text(json.dumps(cfg_for(srv)))
            code = auth.main(["--expected", str(cfg_path), "--out-dir", tmp,
                              "--skip", "brute_force,account_enumeration,second_factor,tokens"])
            report = json.loads((Path(tmp) / "report.json").read_text())
            self.assertIn("FAILED", (Path(tmp) / "report.md").read_text())
        self.assertEqual(code, 1)
        self.assertTrue(any("reset token" in d for d in report["deviations"]))


if __name__ == "__main__":
    unittest.main()
