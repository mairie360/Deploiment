# Incident response runbook

What to do when a real attack hits an instance (dev, staging, prod, a client's prod), in the order
that works. This is the companion of the disaster-recovery runbook: that one restores a lost
machine or database, this one stops an attack in progress and limits its damage. French version:
[`docs/fr/incident-response.md`](../fr/incident-response.md).

Related references: the external attack campaigns and their rules of engagement
([`docs/en/external-attack-campaigns.md`](external-attack-campaigns.md)), the disaster-recovery
runbook ([`disaster-recovery.md`](disaster-recovery.md)), the network model and Cilium / Hubble
section of `CLAUDE.md`, and the GDPR decisions of each org (`compliance/<org>/`).

## Who decides

| Role | Person | Does |
| --- | --- | --- |
| **Incident lead** | **Quentin** | decides, runs the cut actions, speaks to the mairie, writes the record |
| **Backup lead** | **Hugo** (`CarolinHugo`) | takes the lead role when Quentin is unreachable |
| Reinforcement | `LAURETbenjamin`, `MathTek` | watch the signals, run commands under the lead's direction |

One person is the lead at a time. The lead can delegate a command but stays accountable for the
decision to cut. Reach the team on the usual channel; if neither lead answers within 15 minutes,
whoever is present takes the lead role and records that they did.

## 1. Recognise an attack

Signals to look at, in the order they are quickest to read:

- **Ingress / front logs**: a flood of requests from one address, a spike of 4xx/5xx, a path hit far
  more than usual. On the Argo CD machine (the only one reaching the instance API server):
  `kubectl --context <ctx> -n mairie360-<env> logs -l app.kubernetes.io/component=frontend --since=10m | tail`
  and the ingress controller's logs in its namespace (`traefik` or `ingress-nginx`).
- **Login failures**: a burst of 401/429 on `login.<domain>` or many `attack`-shaped accounts; the
  BFF_user rate limiter answering 429 (per account and per IP). The authentication campaign
  (`security/external/auth/`) is what a benign spike looks like — check it is not a scheduled run.
- **Pod load / restarts**: `kubectl --context <ctx> -n mairie360-<env> top pods` and
  `get pods` — memory near the limit, a pod restarting, an `OOMKilled` event. A denial-of-service
  attempt shows here (see `security/external/dos/`).
- **Network flows (Hubble)**: `scripts/hubble-flows.sh <ctx> <env>` prints every allowed/denied
  flow hop by hop — a hop that should be denied but is allowed, or a new external destination.
- **Cockpit** (metrics / alerts): the `BackupMissed`, `RestoreTooSlow`, memory and request-rate
  series of the instance.

Decide the **type** of what you see: volumetric / denial of service, authentication abuse (brute
force, credential stuffing), an exploited application flaw (injection, access control), or a
supply-chain event (a bad image, a workflow abuse). The cut you reach for depends on it.

## 2. Cut first, by type

Every cut below is an **out-of-band emergency action**: on staging and prod (synced by hand, see
`CLAUDE.md` "Each environment follows its own branch") it holds until the next Argo CD sync, which
will self-heal or prune it. After the incident, either land the change in git (so Argo keeps it) or
lift it. Each is a tested command (`tests/scripts/mair_1194_incident_cuts_test.sh`); dry-run them on
staging during a campaign window before you need them for real.

| Attack | Cut | Command |
| --- | --- | --- |
| One hostile address | block it at the edge | `scripts/incident/block-ip.sh <ip\|cidr> --context <ctx>` (lift: `--remove`) |
| One front under abuse | close that route | `scripts/incident/close-route.sh <front-instance> --context <ctx> --namespace mairie360-<env>` (reopen: `--remove`) |
| Whole instance overwhelmed | maintenance (public surface down) | `scripts/incident/maintenance.sh on --context <ctx> --namespace mairie360-<env>` (lift: `off` then re-sync Argo CD) |
| Session / token compromise | revoke **every** session | `scripts/seal-secrets.sh <ctx> <org> <env> --rotate-signing-key` then the two-commit rollout of `CLAUDE.md` "session signing key"; everyone signs in again |
| A secret leaked | rotate it | `scripts/seal-secrets.sh <ctx> <org> <env> --rotate` (or `--rotate-roles` for the DB/Redis role passwords), sync, restart the pods that read it |
| A bad / unsigned image | stop the promotion, verify what runs | `scripts/check-signed-images.sh` (step 16 of `verify.sh`) tells which running digest is unsigned; roll the instance back to the last good tag in git and sync |

Order within an incident: **stop the bleeding** (block the address or close the route if the attack
is localised; maintenance if it is not), **then** contain (revoke sessions / rotate a leaked secret),
**then** investigate. Do not rotate a secret before you have blocked the way the attacker reached it,
or they will use the rotation window.

## 3. Warn the mairie, and the GDPR clock

- **When**: tell the affected mairie as soon as the incident is confirmed and you have a first fact
  to give them (what is down, what you are doing). Do not wait for the full analysis.
- **Who**: the incident lead, by the agreed contact of that org (`compliance/<org>/access.yaml` holds
  who has access; the mairie's DPO is named in its DPIA).
- **Personal data breach**: if personal data may have been read, changed, exfiltrated or lost, the
  GDPR 72-hour notification clock starts at the moment you become aware. Open the breach procedure of
  `compliance/<org>/deadlines.yaml` (`breach-exercise` is the yearly drill of exactly this), assess
  whether the mairie must notify the CNIL and the people concerned, and record the timeline. Mairie
  360 is the processor; the mairie is the controller and makes the notification — give them the facts
  in time.

## 4. Traces to keep

Collect and keep, out of the cluster, before anything is scaled or pruned:

- the ingress / front / API logs of the window: `kubectl ... logs ... --since=<window> > incident-<date>-<svc>.log`;
- the Hubble flows of the window (`scripts/hubble-flows.sh`), and the Cockpit graphs (screenshot or export);
- `kubectl ... get events --sort-by=.lastTimestamp` and `get pods -o wide` at the time;
- the exact cut commands you ran and when (keep your shell history / a short log);
- for a data breach: what data, how many people, the access path, in the breach record.

Store them in the incident's Jira ticket (attachments) and, for a breach, in the mairie's compliance
file. Never paste a secret or personal data into the ticket; mask values.

## 5. After: close the loop

- **Finding register**: every confirmed weakness the attack used becomes an entry in the
  vulnerability register, like a campaign finding.
- **Ticket**: open a Jira ticket per fix (one per repo touched), under the right epic, following the
  normal flow.
- **Non-regression test**: the fix ships with a test that fails on the old behaviour and passes on
  the fix, on the layer that observed it (see the root `CLAUDE.md` rule) — so the same attack cannot
  land twice silently.
- **Lift the emergency cuts**: remove the `incident-*` policies and the maintenance scaling (or land
  them in git if they must stay), and re-sync Argo CD so the instance matches git again.
- **Update this runbook**: if a cut was missing or a signal was slow to read, add it here.

## Drill

A dry-run exercise of this runbook is played during the first external attack campaign:
on staging, in a window, run each cut command and its reverse, time the detection, and record what
to improve. The yearly personal-data-breach exercise (`compliance/<org>/deadlines.yaml`,
`breach-exercise`) rehearses section 3.
