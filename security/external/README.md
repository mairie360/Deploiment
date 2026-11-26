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

Tests: `tests/security/test_mair_1186_external_recon.py` (CI).
