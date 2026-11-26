"""Active DAST driver: header/cookie/probe checks, tool-report parsers, gate."""
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
SCRIPT = ROOT / "security" / "external" / "dast" / "dast.py"
EXPECTED = ROOT / "security" / "external" / "dast" / "expected.json"
FIX = ROOT / "security" / "external" / "dast" / "fixtures"
spec = importlib.util.spec_from_file_location("dast", SCRIPT)
dast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dast)

CFG = json.loads(EXPECTED.read_text())
SECURE_HEADERS = {
    "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
    "Content-Security-Policy": "default-src 'self'; script-src 'self'",
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
}


class Headers(unittest.TestCase):
    def test_mair_1190_secure_headers_have_no_finding(self):
        self.assertEqual(dast.header_findings("project", SECURE_HEADERS, CFG), [])

    def test_mair_1190_missing_and_weak_headers(self):
        headers = {"Strict-Transport-Security": "max-age=60", "Content-Security-Policy": "default-src 'self' 'unsafe-inline'"}
        titles = [f["title"] for f in dast.header_findings("project", headers, CFG)]
        self.assertTrue(any("max-age below" in t for t in titles))
        self.assertTrue(any("missing header x-frame-options" in t for t in titles))
        self.assertTrue(any("CSP allows unsafe-inline" in t for t in titles))

    def test_mair_1190_clickjacking_header_wrong_value(self):
        headers = dict(SECURE_HEADERS, **{"X-Frame-Options": "ALLOWALL"})
        titles = [f["title"] for f in dast.header_findings("project", headers, CFG)]
        self.assertTrue(any("x-frame-options" in t for t in titles))


class Cookies(unittest.TestCase):
    def test_mair_1190_secure_session_cookie_ok(self):
        c = ["accessToken=abc; Path=/; Secure; HttpOnly; SameSite=Lax"]
        self.assertEqual(dast.cookie_findings("login", c, CFG), [])

    def test_mair_1190_missing_cookie_flags_are_high(self):
        c = ["accessToken=abc; Path=/"]
        f = dast.cookie_findings("login", c, CFG)
        self.assertTrue(f and all(x["severity"] == "high" for x in f))
        self.assertEqual({x["title"].split("without ")[1] for x in f}, {"Secure", "HttpOnly", "SameSite"})


class Parsers(unittest.TestCase):
    def test_mair_1190_zap_riskcodes_map_to_severities(self):
        out = dast.parse_zap(json.loads((FIX / "zap-sample.json").read_text()))
        sev = sorted(f["severity"] for f in out)
        self.assertEqual(sev, ["high", "informational", "low", "medium"])
        self.assertTrue(any("SQL Injection" in f["title"] and f["severity"] == "high" for f in out))

    def test_mair_1190_testssl_keeps_only_rated_entries(self):
        out = dast.parse_testssl(json.loads((FIX / "testssl-sample.json").read_text()))
        self.assertEqual(len(out), 2)  # OK entry dropped
        self.assertTrue(any(f["severity"] == "high" and "RC4" in f["title"] for f in out))

    def test_mair_1190_sqlmap_reports_injectable_parameter(self):
        out = dast.parse_sqlmap((FIX / "sqlmap-sample.log").read_text())
        self.assertTrue(out and out[0]["severity"] == "high" and "sort" in out[0]["title"])

    def test_mair_1190_sqlmap_clean_log_has_no_finding(self):
        self.assertEqual(dast.parse_sqlmap((FIX / "sqlmap-clean.log").read_text()), [])


class Gate(unittest.TestCase):
    def test_mair_1190_high_fails_and_sorts_first(self):
        findings = [dast.finding("low", "x", "a"), dast.finding("high", "y", "b"), dast.finding("medium", "z", "c")]
        ordered, failed = dast.gate(findings)
        self.assertTrue(failed)
        self.assertEqual([f["severity"] for f in ordered], ["high", "medium", "low"])

    def test_mair_1190_medium_is_a_finding_not_a_failure(self):
        _, failed = dast.gate([dast.finding("medium", "x", "a"), dast.finding("low", "y", "b")])
        self.assertFalse(failed)


class Probes(unittest.TestCase):
    """open redirect / path traversal / SSRF against a fake vulnerable front."""

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, status, body="", headers=None):
            self.send_response(status)
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            data = body.encode()
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path.startswith("/api/auth/logout"):
                loc = self.path.split("redirect=", 1)[1] if "redirect=" in self.path else "/"
                return self._send(302, headers={"Location": loc})
            if self.path.startswith("/elearning/files/"):
                return self._send(200, "root:x:0:0:root:/root:/bin/bash\n")
            self._send(404, "{}")

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            self.rfile.read(length)
            if self.path == "/message/link-preview":
                return self._send(200, '{"title":"instance-id ami-id iam/role"}')
            self._send(404, "{}")

    def setUp(self):
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), self.Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        base = f"https://127.0.0.1:{self.srv.server_address[1]}"
        # Route every front to the fake server over http (the probes don't need TLS here).
        self.patch = mock.patch.object(dast, "front_url",
                                       lambda cfg, front, path="": f"http://127.0.0.1:{self.srv.server_address[1]}{path}")

    def tearDown(self):
        self.srv.shutdown()

    def test_mair_1190_open_redirect_detected(self):
        with self.patch:
            out = dast.open_redirect_findings(CFG, {"user": {}})
        self.assertTrue(out and out[0]["severity"] == "medium" and "open redirect" in out[0]["title"])

    def test_mair_1190_path_traversal_detected(self):
        with self.patch:
            out = dast.path_traversal_findings(CFG, {"user": {}})
        self.assertTrue(out and out[0]["severity"] == "high" and "path traversal" in out[0]["title"])

    def test_mair_1190_ssrf_detected(self):
        with self.patch:
            out = dast.ssrf_findings(CFG, {"user": {}})
        self.assertTrue(out and out[0]["severity"] == "high" and "SSRF" in out[0]["title"])


class Cli(unittest.TestCase):
    def test_mair_1190_aggregates_tool_reports_and_fails_on_high(self):
        with tempfile.TemporaryDirectory() as tmp:
            code = dast.main(["--out-dir", tmp, "--skip-http",
                              "--zap", str(FIX / "zap-sample.json"),
                              "--testssl", str(FIX / "testssl-sample.json"),
                              "--sqlmap", str(FIX / "sqlmap-sample.log")])
            report = json.loads((Path(tmp) / "report.json").read_text())
            md = (Path(tmp) / "report.md").read_text()
        self.assertEqual(code, 1)
        self.assertTrue(report["failed"])
        self.assertEqual(report["findings"][0]["severity"], "high")
        self.assertIn("FAILED", md)
        self.assertEqual({f["source"] for f in report["findings"]}, {"zap", "testssl", "sqlmap"})

    def test_mair_1190_clean_tool_reports_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            code = dast.main(["--out-dir", tmp, "--skip-http", "--sqlmap", str(FIX / "sqlmap-clean.log")])
        self.assertEqual(code, 0)

    def test_mair_1190_http_checks_need_the_password(self):
        with mock.patch.dict(os.environ, {}, clear=True), tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(dast.main(["--out-dir", tmp]), 2)


class Expected(unittest.TestCase):
    def test_mair_1190_staging_fronts_and_test_accounts(self):
        self.assertTrue(CFG["domain"].startswith("staging."))
        for email in CFG["accounts"].values():
            self.assertTrue(email.endswith("@example.invalid"))
        self.assertEqual(set(CFG["session_cookie_flags"]), {"Secure", "HttpOnly", "SameSite"})


if __name__ == "__main__":
    unittest.main()
