# GDPR decisions (MAIR-294, epic MAIR-284)

One folder per org of `clusters/` (`compliance/<org>/`): the decisions of the mairie, the controller,
that Mairie 360, its processor, applies. Mairie 360 proposes each entry; the mairie validates it
(`validated: {date, by}`). Until then the entry is a proposal: CI reports it as pending.

| File | Decides | Checked against (`scripts/check-compliance.py`) |
| --- | --- | --- |
| `register.yaml` | the record of processing activities (GDPR art. 30): purpose, legal basis, data categories (Devops/Database `gdpr/inventory.yaml`), retention, subprocessors | completeness, subprocessors known |
| `retention.yaml` | retention periods: `retention_policies` tables, technical logs (1 year by default, the mairie may only shorten it), security logs, archived accounts, backups | rendered retention CronJob (`retention.policies`) and backup CronJob (`backup.retention`) of every instance of `applies_to` |
| `subprocessors.yaml` | external services the instance sends data to | every external host of the rendered manifests (URLs, `*_HOST`, SMTP) and every egress CIDR |
| `access.yaml` | people with access to the instance and its machines | Devops/ansible `verify.yml` (MAIR-293) |
| `deadlines.yaml` | recurring compliance tasks (access review, restore test, DPIA, breach exercise) | scheduled n8n workflows open a Jira ticket per overdue deadline (MAIR-295) |

The legal pages of the fronts (MAIR-292) show the retention periods and the subprocessors from
`global.legal` of the instance values (`LEGAL_CONFIG` of the login front, which serves
`/mentions-legales` and `/confidentialite`; every front's footer links there). `global.legal` also
holds the identity of the mairie (name, address, publication director, DPO, host), to complete per
instance. The check fails when its periods or subprocessors (`purpose_fr`) differ from these files.

Changing a period: change it here **and** in the instance's values (`retention.policies`,
`backup.retention`) and `global.legal.retention` in the same PR, or CI fails. The retention CronJob writes `retention.policies`
into `retention_policies` before every purge, so the configuration is the source of the periods.

Decision of 2026-10-08: IP addresses stay in the request and security logs for security; the
per-instance compliance scanner to come removes them and/or backups encrypt them (`retention.yaml`,
`security_logs`).

Run locally: `python3 -m unittest discover -s tests/compliance && ./scripts/check-compliance.py`
(`--strict`: pending validations fail too).
