# External attack scenarios

What the external attack campaigns replay from the Internet against the platform, one folder per
family. Rules of engagement (target, source, accounts, rate caps, stop criteria):
[`docs/en/external-attack-campaigns.md`](../../docs/en/external-attack-campaigns.md).

## `recon/`: monthly reconnaissance

What an attacker sees of the mairie360 group before attacking. `recon.py` (standard library,
plus `nmap`, `git` and `docker`) collects:

| Check | How | Fails when |
| --- | --- | --- |
| Open ports | `nmap -sT` of every machine of `hosts`, ports `scan_ports`, `max_rate` probes per second per host (1, the cap of the rules of engagement), machines in parallel | a port outside the machine's `tcp` list answers, or a scan fails |
| Subdomains | names of the still-valid certificates of the zone in the certificate transparency logs (Cert Spotter API) | a name is not in `subdomains`, or the lookup fails |
| Version banners | `Server`, `X-Powered-By` and similar headers of `banner_urls`, version strings of a 404 page | any product version is shown |
| Admin interfaces | `admin_interfaces` (n8n editor, Argo CD, Kubernetes API) | one answers with a status below 500 |
| Secrets | gitleaks (image pinned by digest, as in mairie360/CICD) on the full history of every public repository of `github_org` | a finding is not in `accepted_leaks` (repository + fingerprint) |
| DNS records | every record of `dns.zones` (Scaleway Domains API, read-only key `SCW_SECRET_KEY`, secret `RECON_DNS_SCW_SECRET_KEY`) | an A/AAAA record points outside the machines of `hosts` and `dns.known_addresses` (orphan record), a CNAME/MX target does not resolve (subdomain takeover), or the key is missing |
| Anti-spoofing | public TXT records of each `dns.mail_domains` entry | not exactly one SPF ending with `-all`/`~all`, a DKIM selector without key, not exactly one DMARC record, a policy outside `dmarc_policies`, no `rua` report address |

`findings_to_close` are expected today but reported at every run (public SSH, until WireGuard is
the only way in).

```bash
# Everything (about an hour: 1 probe per second per host)
python3 security/external/recon/recon.py --out-dir report/ --previous previous/recon.json
# Without the port scan and gitleaks, to check the rest quickly
python3 security/external/recon/recon.py --out-dir report/ --skip ports,gitleaks
```

It writes `recon.json` and `recon.md` (deviations, known findings, changes since `--previous`,
open ports, subdomains, repositories scanned) and exits 1 on any deviation.
`.github/workflows/external-recon.yaml` runs it on the first Monday of every month and on demand,
publishes the report as the `external-recon` artifact (400 days) and in the job summary, and
compares it with the report of the previous run.

A deviation is either fixed (close the port, remove the DNS record, hide the banner, rotate and
purge the secret) or, when it is wanted, added to `expected.json` in a reviewed pull request. Each
real finding goes to the vulnerability register with its MAIR ticket.

Tests: `tests/security/test_mair_1186_external_recon.py`, `tests/security/test_mair_1187_dns_mail.py` (CI).

## `auth/`: monthly authentication scenarios

Black-box authentication attacks replayed against staging through the ingress (`auth/auth.py`,
standard library only), one scenario per family, capped at `rate_per_second` requests
(`auth/expected.json`):

| Scenario | What it does | A finding when |
| --- | --- | --- |
| Brute force | wrong logins for one test account, then failed logins over many accounts from one address | no 429 appears per account or per IP, or locking one account blocks another before the per-IP budget is spent |
| Account enumeration | a known and an unknown account on login and forgot-password | status, body length or timing tells them apart |
| Second factor | a forged / 2FA-pending token on the session route, bursts of 2FA codes | the partial token reaches a session, a forged code is accepted, or codes are not rate-limited |
| Password reset | a modified `Host`, a forged and a random reset token | the Host is reflected in the answer, or a forged / random token is accepted |
| Tokens | JWT with `alg` none, HS256 (weak-secret wordlist) or a tampered signature; a replayed refresh token | a forged token is accepted on the session route, or a refresh token is accepted twice |

The attacker never signs a valid token: `none` / HS256 / tamper need no key. The scoped-lockout and
refresh-replay checks need a valid login, so they read the test-account password from
`AUTH_TEST_PASSWORD` (plaintext of `TEST_ACCOUNTS_PASSWORD`); without it they are skipped.

```bash
# Every scenario against staging (locks the attack.* test accounts on purpose)
AUTH_TEST_PASSWORD=... python3 security/external/auth/auth.py --out-dir report/
# Only the forging checks, no burst
python3 security/external/auth/auth.py --out-dir report/ --skip brute_force,account_enumeration,second_factor
```

It writes `report.json` / `report.md` and exits 1 on any finding.
`.github/workflows/external-auth.yaml` runs it on the first Monday of every month and on demand,
staging only (artifact `external-auth`, 400 days). Each finding goes to the vulnerability register
with its MAIR ticket; fixing one is its own ticket.

Tests: `tests/security/test_mair_1188_auth_scenarios.py` (CI).

## `access/`: monthly access-control scenarios

Behavioural access-control attacks replayed against staging through the **front origins**
(`access/access.py`, standard library only). The per-API `access-matrix.yaml` are the source of
the expected allow/deny, but the front paths are BFF-reshaped, so the scenarios use the fronts'
own CRUD paths, not a 1:1 map of the matrices (matrix completeness stays enforced per-API by each
API's `tests/endpoints/access_matrix.rs`). Families:

| Family | What it does | A finding when |
| --- | --- | --- |
| Elevation | a Guest session calls every operation of the admin front | one answers 2xx instead of 403/401 |
| IDOR | one account creates a resource through its front, another account tries GET/PATCH/DELETE on it | the other account gets 2xx, and a data leak when the answer carries the owner's marker |

It signs the `attack.*` test accounts in with `AUTH_TEST_PASSWORD` (plaintext of
`TEST_ACCOUNTS_PASSWORD`); without it nothing runs. Each IDOR case creates then deletes a
disposable resource. Compliance_API has no matrix yet (follow-up ticket); the five others do.

```bash
AUTH_TEST_PASSWORD=... python3 security/external/access/access.py --out-dir report/
```

It writes `report.json` / `report.md` and exits 1 on any finding.
`.github/workflows/external-access.yaml` runs it on the first Monday of every month and on demand,
staging only (artifact `external-access`, 400 days). Each finding goes to the vulnerability
register with its MAIR ticket; fixing one is its own ticket.

Tests: `tests/security/test_mair_1189_access_scenarios.py` (CI).

## `dast/`: active DAST (manual, announced window)

Active scan of the public front origins of staging (through the ingress), run **by hand in an
announced campaign window** (`.github/workflows/external-dast.yaml`, `workflow_dispatch` only): it
sends real injection payloads and writes on staging. 10 requests per second, 5 threads. Pipeline:

| Tool | What it covers |
| --- | --- |
| ZAP (active scan) | injection, XSS, CSRF, clickjacking, missing headers; OpenAPI coverage through the ingress with the `CICD/tests/zap` hook, a session per role |
| sqlmap | the declared filter/sort parameters |
| testssl.sh | the real TLS of each front |
| `dast.py` (standard library) | security headers, the session cookie's flags (Secure/HttpOnly/SameSite), open redirect, path traversal, SSRF |

`dast.py` also folds every tool's report (ZAP JSON, testssl.sh JSON, sqlmap log) into one findings
list and gates: **a High alert fails the run** (exit 1), a Medium is a finding for the register. It
signs a test account in with `AUTH_TEST_PASSWORD` for the authenticated probes.

```bash
# Aggregate tool reports and run the driver's own HTTP checks
AUTH_TEST_PASSWORD=... python3 security/external/dast/dast.py --out-dir report/ \
  --zap report/zap-project.json --testssl report/testssl-project.json --sqlmap report/sqlmap.log
```

The report (artifact `external-dast`) is attached to the ticket. Each High is fixed before the next
window; each Medium goes to the vulnerability register. Tests:
`tests/security/test_mair_1190_active_dast.py` (CI).

