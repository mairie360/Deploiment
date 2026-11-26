#!/usr/bin/env python3
"""Black-box authentication scenarios of the external attack campaigns.

    AUTH_TEST_PASSWORD=... security/external/auth/auth.py --out-dir report/ [--skip tokens]

Replays, against a deployed instance through its ingress (staging, expected.json `base_url`), the
attacks an unauthenticated attacker runs on the Login front:

- brute force / credential stuffing: a progressive block per account and per IP must appear, and it
  must stay scoped (a second account still logs in);
- account enumeration: login and forgot-password must answer the same, in body and in timing,
  whether the account exists or not;
- second-factor bypass: a partial (2FA-pending) token reaches no session route, a forged 2FA token
  is refused, and 2FA attempts are rate-limited;
- password reset hijacking, without reading the e-mail (the test accounts are undeliverable): a
  modified Host header is not reflected, a forged or random reset token is refused;
- tokens: a JWT with alg none, alg HS256 (weak-secret wordlist) or a tampered signature, and a
  replayed refresh token, are all refused — the refresh replay closes the session.

Each weakness is a deviation: the report (report.json / report.md, --out-dir) lists them and the
script exits 1, so a campaign run surfaces them for the findings register. Fixing one is its own
ticket. Capped at `rate_per_second` requests (rules of engagement, docs/en/external-attack-campaigns.md).
The attacker never signs a valid token: alg none / HS256 / tamper need no key. Standard library only.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import ssl
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
USER_AGENT = "mairie360-auth-campaign"


# --------------------------------------------------------------------------- HTTP

class RateLimiter:
    """At most `rate` requests per second, shared across threads."""

    def __init__(self, rate):
        self._min_interval = 1.0 / rate if rate > 0 else 0.0
        self._lock = threading.Lock()
        self._next = 0.0

    def wait(self):
        with self._lock:
            now = time.monotonic()
            start = max(now, self._next)
            self._next = start + self._min_interval
        delay = start - now
        if delay > 0:
            time.sleep(delay)


def _context():
    ctx = ssl.create_default_context()
    # The attacker does not trust the certificate; staging may run the Let's Encrypt staging chain.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def http(method, url, limiter, headers=None, body=None, cookies=None, timeout=15):
    """(status, headers, body_text, elapsed_ms, set_cookies) of one request; status 0 on a transport error."""
    limiter.wait()
    data = None
    sent = {"User-Agent": USER_AGENT, "Accept": "application/json", **(headers or {})}
    if body is not None:
        data = json.dumps(body).encode()
        sent["Content-Type"] = "application/json"
    if cookies:
        sent["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
    req = urllib.request.Request(url, data=data, method=method, headers=sent)
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_context()) as resp:
            text = resp.read(65536).decode("utf-8", "replace")
            return resp.status, dict(resp.headers), text, _ms(start), _set_cookies(resp.headers)
    except urllib.error.HTTPError as err:
        text = err.read(65536).decode("utf-8", "replace")
        return err.code, dict(err.headers), text, _ms(start), _set_cookies(err.headers)
    except (urllib.error.URLError, OSError, ValueError) as err:
        return 0, {}, str(err)[:200], _ms(start), {}


def _ms(start):
    return round((time.monotonic() - start) * 1000, 1)


def _set_cookies(headers):
    jar = {}
    for raw in headers.get_all("Set-Cookie", []) if hasattr(headers, "get_all") else []:
        pair = raw.split(";", 1)[0].strip()
        if "=" in pair:
            name, value = pair.split("=", 1)
            jar[name] = value
    return jar


# --------------------------------------------------------------------------- JWT forging

def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def forge_jwt(payload, alg="none", secret=""):
    """A JWT the attacker can build with no private key: alg none, or HS256 with a guessed secret."""
    header = {"alg": alg, "typ": "JWT"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    if alg == "none":
        return f"{signing_input}."
    if alg == "HS256":
        sig = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
        return f"{signing_input}.{b64url(sig)}"
    raise ValueError(f"unsupported alg {alg}")


def tamper(token):
    """Flip the last character of a real token's signature (a forged EdDSA signature)."""
    head, _, _ = token.rpartition(".")
    last = token[-1]
    return f"{head}.{'A' if last != 'A' else 'B'}"


def admin_payload():
    """A claim set an attacker would wish signed: far-future expiry, an admin-looking subject."""
    now = int(time.time())
    return {"sub": "1", "role": "Admin", "email": "attack.forged@example.invalid",
            "iat": now, "exp": now + 3600}


# --------------------------------------------------------------------------- scenarios

def login(cfg, limiter, email, password, headers=None):
    return http("POST", cfg["base_url"] + cfg["endpoints"]["login"], limiter,
                headers=headers, body={"email": email, "password": password, "device_info": "campaign"})


def brute_force(cfg, limiter):
    """A per-account and per-IP block must appear, scoped so another account still logs in."""
    findings, obs = [], {}
    primary = cfg["accounts"]["primary"]
    account_max = cfg["login_lockout_max"]
    statuses = []
    for _ in range(account_max + 6):
        status, _, _, _, _ = login(cfg, limiter, primary, "wrong-" + os.urandom(4).hex())
        statuses.append(status)
    obs["per_account_statuses"] = statuses
    if 429 not in statuses:
        findings.append(f"no per-account block: {account_max + 6} wrong logins for {primary}, "
                        f"never a 429 (statuses {sorted(set(statuses))})")

    # Scoped lockout: a valid login to a SECOND account, from the same address, must still succeed
    # while the per-IP budget is not yet spent — else locking one account locks others (instance-wide
    # lockout an attacker can trigger). Checked before the per-IP spray so the per-IP block (expected,
    # and only affecting the attacker's own address) does not confound it.
    password = os.environ.get("AUTH_TEST_PASSWORD")
    if password:
        status, _, _, _, _ = login(cfg, limiter, cfg["accounts"]["secondary"], password)
        obs["other_account_login_status"] = status
        if status == 429:
            findings.append("locking one account blocks a second account from the same address before "
                            "the per-IP budget is spent: an attacker can lock accounts out instance-wide")
    else:
        obs["other_account_login_status"] = "skipped (no AUTH_TEST_PASSWORD)"

    ip_max = cfg["ip_lockout_max"]
    ip_statuses = []
    for i in range(ip_max + 6):
        status, _, _, _, _ = login(cfg, limiter, f"attack.spray{i}@example.invalid", "wrong")
        ip_statuses.append(status)
    obs["per_ip_statuses_tail"] = ip_statuses[-6:]
    if 429 not in ip_statuses:
        findings.append(f"no per-IP block: {ip_max + 6} failed logins from one address over distinct "
                        f"accounts, never a 429")
    return findings, obs


def _signal(cfg, limiter, email):
    """What login and forgot-password reveal for one e-mail: status, a body fingerprint and timing."""
    runs = 5
    login_times, forgot_times = [], []
    login_status = forgot_status = 0
    login_body = forgot_body = ""
    for _ in range(runs):
        s, _, b, t, _ = login(cfg, limiter, email, "wrong-" + os.urandom(4).hex())
        login_status, login_body = s, b
        login_times.append(t)
        s, _, b, t, _ = http("POST", cfg["base_url"] + cfg["endpoints"]["forgot_password"], limiter,
                             body={"email": email})
        forgot_status, forgot_body = s, b
        forgot_times.append(t)
    return {"login_status": login_status, "login_len": len(login_body),
            "login_ms": round(statistics.median(login_times), 1),
            "forgot_status": forgot_status, "forgot_len": len(forgot_body),
            "forgot_ms": round(statistics.median(forgot_times), 1)}


def account_enumeration(cfg, limiter):
    """Login and forgot-password must not tell an existing account from an unknown one."""
    existing = _signal(cfg, limiter, cfg["accounts"]["primary"])
    unknown = _signal(cfg, limiter, cfg["accounts"]["unknown"])
    obs = {"existing": existing, "unknown": unknown}
    out = []
    if existing["login_status"] != unknown["login_status"]:
        out.append(f"login status differs: {existing['login_status']} for a known account vs "
                   f"{unknown['login_status']} for an unknown one")
    if existing["forgot_status"] != unknown["forgot_status"]:
        out.append(f"forgot-password status differs: {existing['forgot_status']} vs {unknown['forgot_status']}")
    if existing["login_len"] != unknown["login_len"]:
        out.append(f"login body length differs ({existing['login_len']} vs {unknown['login_len']}): "
                   "the message tells the accounts apart")
    ratio = cfg["timing_ratio"]
    if unknown["login_ms"] > 0 and existing["login_ms"] / unknown["login_ms"] >= ratio:
        out.append(f"login timing leaks existence: {existing['login_ms']} ms for a known account vs "
                   f"{unknown['login_ms']} ms for an unknown one (>= {ratio}x; hash only when the account exists?)")
    return out, obs


def second_factor(cfg, limiter):
    """A partial 2FA token reaches no session, a forged 2FA token is refused, attempts are limited."""
    out, obs = [], {}
    session_url = cfg["base_url"] + cfg["endpoints"]["session"]
    forged = forge_jwt({**admin_payload(), "twofa_pending": True}, alg="none")
    status, _, _, _, _ = http("GET", session_url, limiter, cookies={cfg["session_cookie"]: forged})
    obs["partial_token_session_status"] = status
    if status == 200:
        out.append("a 2FA-pending / forged session token is accepted on the session route (second "
                   "factor skipped)")
    statuses = []
    for _ in range(cfg["login_lockout_max"] + 3):
        s, _, _, _, _ = http("POST", cfg["base_url"] + cfg["endpoints"]["login_2fa"], limiter,
                             body={"token": forge_jwt(admin_payload()), "code": "000000"})
        statuses.append(s)
    obs["twofa_attempt_statuses"] = sorted(set(statuses))
    if 200 in statuses:
        out.append("a forged 2FA token with a guessed code was accepted")
    elif 429 not in statuses:
        out.append(f"2FA code attempts are not rate-limited ({len(statuses)} tries, statuses "
                   f"{sorted(set(statuses))}): brute force of the 6-digit code is open")
    return out, obs


def password_reset(cfg, limiter):
    """A modified Host is not honoured, a forged or random reset token is refused."""
    out, obs = [], {}
    evil = "attacker.example"
    status, headers, body, _, _ = http("POST", cfg["base_url"] + cfg["endpoints"]["forgot_password"],
                                       limiter, headers={"Host": evil, "X-Forwarded-Host": evil},
                                       body={"email": cfg["accounts"]["primary"]})
    obs["forgot_with_evil_host_status"] = status
    if evil in body or evil in headers.get("Location", ""):
        out.append(f"the forgot-password response reflects the attacker Host '{evil}': the reset link "
                   "may point at it (Host-header poisoning)")
    for label, token in (("forged", forge_jwt(admin_payload())), ("random", os.urandom(24).hex())):
        s, _, _, _, _ = http("POST", cfg["base_url"] + cfg["endpoints"]["reset_password"], limiter,
                             body={"token": token, "new_password": "Campaign-" + os.urandom(6).hex(),
                                   "device_info": "campaign"})
        obs[f"reset_{label}_token_status"] = s
        if s == 200:
            out.append(f"a {label} reset token was accepted: a password reset can be forced without the e-mail")
    return out, obs


def tokens(cfg, limiter):
    """Forged session tokens are refused; a replayed refresh token is refused and closes the session."""
    out, obs = [], {}
    session_url = cfg["base_url"] + cfg["endpoints"]["session"]
    forged = {"alg none": forge_jwt(admin_payload(), alg="none"),
              "tampered signature": tamper(forge_jwt(admin_payload(), alg="HS256", secret="x"))}
    for secret in cfg.get("hs256_wordlist", []):
        forged[f"HS256 secret '{secret}'"] = forge_jwt(admin_payload(), alg="HS256", secret=secret)
    accepted = []
    for label, token in forged.items():
        status, _, _, _, _ = http("GET", session_url, limiter, cookies={cfg["session_cookie"]: token})
        if status == 200:
            accepted.append(label)
    obs["forged_token_count"] = len(forged)
    obs["forged_accepted"] = accepted
    if accepted:
        out.append("forged session token(s) accepted on the session route: " + ", ".join(accepted))

    password = os.environ.get("AUTH_TEST_PASSWORD")
    if not password:
        obs["refresh_replay"] = "skipped (no AUTH_TEST_PASSWORD)"
        return out, obs
    account = cfg["accounts"]["refresh"]
    status, _, body, _, jar = login(cfg, limiter, account, password)
    obs["refresh_login_status"] = status
    refresh_token = jar.get("refreshToken")
    if not refresh_token:
        try:
            refresh_token = json.loads(body).get("refresh_token")
        except (ValueError, AttributeError):
            refresh_token = None
    if status != 200 or not refresh_token:
        obs["refresh_replay"] = f"skipped (login {status}, no refresh token for {account})"
        return out, obs
    refresh_url = cfg["base_url"] + cfg["endpoints"]["refresh"]
    first, _, _, _, _ = http("POST", refresh_url, limiter, body={"refresh_token": refresh_token})
    second, _, _, _, _ = http("POST", refresh_url, limiter, body={"refresh_token": refresh_token})
    obs["refresh_replay"] = {"first": first, "second": second}
    if second == 200:
        out.append("a refresh token is accepted twice: refresh-token rotation does not invalidate the "
                   "used token (replay keeps the session alive)")
    return out, obs


SCENARIOS = {
    "brute_force": brute_force,
    "account_enumeration": account_enumeration,
    "second_factor": second_factor,
    "password_reset": password_reset,
    "tokens": tokens,
}


# --------------------------------------------------------------------------- run and report

def run(cfg, skip):
    report = {"base_url": cfg["base_url"], "scenarios": {}, "deviations": []}
    limiter = RateLimiter(cfg.get("rate_per_second", 5))
    for name, func in SCENARIOS.items():
        if name in skip:
            report["scenarios"][name] = {"skipped": True}
            continue
        findings, obs = func(cfg, limiter)
        report["scenarios"][name] = {"findings": findings, "observations": obs}
        report["deviations"] += [f"{name}: {f}" for f in findings]
    return report


def render_markdown(report):
    lines = [f"# External attack campaign — authentication, {report['date']}", "",
             f"Target: `{report['base_url']}`.", ""]
    status = "FAILED" if report["deviations"] else "OK"
    lines += [f"**{status}**: {len(report['deviations'])} finding(s).", "", "## Findings", ""]
    lines += [f"- {d}" for d in report["deviations"]] or ["- none"]
    lines += ["", "## Scenarios", ""]
    for name, result in report["scenarios"].items():
        if result.get("skipped"):
            lines.append(f"- **{name}**: skipped")
            continue
        verdict = "FAILED" if result["findings"] else "ok"
        lines.append(f"- **{name}**: {verdict} ({len(result['findings'])} finding(s))")
    lines.append("")
    return "\n".join(lines)


def main(argv=None):
    import datetime

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--expected", default=str(HERE / "expected.json"))
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--skip", default="", help="comma-separated: " + ", ".join(SCENARIOS))
    args = parser.parse_args(argv)
    skip = {s for s in args.skip.split(",") if s}

    cfg = json.loads(Path(args.expected).read_text())
    report = run(cfg, skip)
    report["date"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (out / "report.md").write_text(render_markdown(report) + "\n")
    print(render_markdown(report))
    return 1 if report["deviations"] else 0


if __name__ == "__main__":
    sys.exit(main())
