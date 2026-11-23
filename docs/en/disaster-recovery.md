# Disaster recovery runbook

What to do when an instance (dev, staging, prod, a client's prod) loses its data or its
machine, in the order that works. French version: [`docs/fr/disaster-recovery.md`](../fr/disaster-recovery.md).

Related reference: the backup chart (`charts/mairie360-stack/charts/backup/README.md`, how
backups are taken and the restore Job), the `ansible` repository (`README.md`, phases and
secrets), `scripts/verify.sh` (acceptance test of an instance).

## Objectives (RPO / RTO)

| | Target | Where it comes from |
| --- | --- | --- |
| **RPO**, data that can be lost | **6 hours** of writes in the Mairie360 database | One backup every 6 hours (`backup.schedule`, `0 */6 * * *` UTC); `mairie360/Infra` alerts (`BackupMissed`) after 7 hours without one. No WAL archiving, no point-in-time recovery, no replica. An instance on CloudNativePG (`database.engine: cnpg`) with `database.cnpg.backup.enabled: true` archives its WAL continuously: its RPO is the last archived WAL segment, restorable to any second between the generation's first recovery point and that segment, over at most the last 35 days ([`cloudnativepg.md`](cloudnativepg.md)). Without that backup, no WAL is archived and the RPO stays the 6-hourly dump. |
| **RTO**, database restored on a working machine | **1 hour** | Scenario A below. Measured every week by the restore test (`backup.restoreTest`), which alerts (`RestoreTooSlow`) above 1 hour and when it has not succeeded for 8 days (`RestoreTestMissed`). |
| **RTO**, lost instance machine rebuilt | **2 hours** | Scenario B: new machine, phases 1 to 3, Argo CD sync, restore, checks. Let's Encrypt certificates and DNS propagation are part of it. |
| **RTO**, lost Argo CD machine | **2 hours** | Scenario C: the instances keep running meanwhile, only deployments stop. |

Never recovered: Redis (session revocation list and caches: users sign in again), the
files of the e-learning Object Storage bucket are not covered by these backups (they live
in Scaleway Object Storage, outside the machine), and anything written after the snapshot.

The RPO and the instance RTO are the ones promised to the mairie: they are decided in
`compliance/<org>/service-levels.yaml`, shown on the instance's legal pages
(`global.legal.serviceLevels`) and checked by `scripts/check-compliance.py` (a backup schedule
leaving more than the RPO between two backups, or legal pages showing other values, fail CI).
Change all three together.

Review these targets after each drill (see "Drill log" at the end).

## What you need before starting

Kept **outside** the lost machine, in the team vault (the shared password manager):

| Item | File the ansible role writes | Without it |
| --- | --- | --- |
| Sealing key(s) of the instance | `~/.mairie360/sealing-keys/<org>-<env>.yaml` | every committed `secrets.yaml` of the instance is undecryptable: reseal everything (scenario D) |
| `RESTIC_PASSWORD` of the backup bucket | `~/.mairie360/restic-<org>-<env>.txt` | **every backup is unreadable**, nothing can be restored |
| First admin password | `~/.mairie360/admin-<org>-<env>.txt` | only needed if the admin account is recreated |

Phase 4 of `ansible` writes these files on the operator's workstation after every run:
copy them to the vault each time (`ansible` README, "Backups of the generated secrets").
The sealing key file holds every key the controller had at that run; the controller renews
its key every 30 days, so the copy must be at least as recent as the last committed
`secrets.yaml`.

Also needed: the local `ansible` inventory (`inventory/hosts.yml`, not in git), the
Scaleway console (machines, DNS, the backup bucket), a `Deploiment` checkout next to
`ansible`, `kubectl`, `jq`, `helm`.

## Scenario A: data lost or corrupted, the machine is fine

1. **Pick the snapshot.** From a machine whose kube context reaches the instance (the
   group's Argo CD machine, `/root/.kube/instance-<env>.yaml`):

   ```bash
   ./scripts/list-snapshots.sh <kube-context> <env>
   # one lineage only: --host <POSTGRES_DB>
   ./scripts/list-snapshots.sh <kube-context> <env> snapshots --host <POSTGRES_DB>
   ```

   It runs `restic snapshots` in a throwaway pod built from the instance's backup CronJob
   (same image, keys, labels); nothing secret leaves the cluster. Note the id of the last
   snapshot taken **before** the incident.

2. **Stop the writers.** Every connection to the database must be closed: an open
   transaction blocks the restore, and anything written during the restore is lost.

   ```bash
   NS=mairie360-<env>
   # Argo CD would scale them back up: pause it first if the Application syncs on its own
   # (dev, and staging when its automated sync is on). On the group's Argo CD machine:
   sudo kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0
   sudo kubectl -n argocd patch application <env> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

   kubectl --context <ctx> -n $NS scale deploy -l app.kubernetes.io/component=api --replicas=0
   kubectl --context <ctx> -n $NS scale deploy -l app.kubernetes.io/component=bff --replicas=0
   kubectl --context <ctx> -n $NS patch cronjob <env>-backup -p '{"spec":{"suspend":true}}'
   kubectl --context <ctx> -n $NS get cronjob -o name | grep retention \
     | xargs -r kubectl --context <ctx> -n $NS patch -p '{"spec":{"suspend":true}}'
   # Suspending a CronJob does not stop a Job it already started: wait for a running
   # backup to end (its pg_dump transaction would hold the restore back).
   # Every backup Job still active (scheduled or created by hand, e.g. <env>-backup-after-restore);
   # finished or failed ones are left out. The restore Job does not exist yet at this step.
   active_backups() {
     kubectl --context <ctx> -n $NS get jobs -o json | jq -r --arg p "<env>-backup-" \
       '.items[] | select(.metadata.name | startswith($p)) | select(.metadata.name != $p + "restore")
        | select((.status.active // 0) > 0) | .metadata.name'
   }
   while [ -n "$(active_backups)" ]; do echo "waiting for: $(active_backups)"; sleep 15; done
   ```

   The ApplicationSet controller rewrites the Application from its template within
   seconds: it must stay at 0 for the patch to hold. While it is stopped, no Application
   of the group is created or updated from the ApplicationSet (deployments of the other
   instances still sync).

3. **Restore** with the restore Job, exactly as the backup chart README says ("Restoring":
   `helm template … -s charts/backup/templates/restore-job.yaml --set
   backup.restore.enabled=true --set backup.restore.snapshotId=<id> --set
   backup.restore.confirmDatabase=<database> | kubectl apply -f -`). Follow it:

   ```bash
   kubectl --context <ctx> -n $NS logs -f job/<env>-backup-restore
   ```

   The Job loads the dump in one transaction: if `pg_restore` fails, the database is left
   as it was. With `backup.sealing.enabled`, that guarantee only covers the load: the dump
   is committed by the `restore` initContainer, then the `unseal` container puts the sealed
   personal data back. If `unseal` fails, the database already holds the snapshot with its
   personal data still sealed: keep the writers stopped, fix the cause (key, secret), delete
   the failed Job (`kubectl --context <ctx> -n $NS delete job <env>-backup-restore`: a Job in
   `Failed` is not started again by a new `apply`) and create it again until it completes. Users erased since the snapshot stay anonymized.

4. **Restart** everything you stopped, in reverse order:

   ```bash
   kubectl --context <ctx> -n $NS patch cronjob <env>-backup -p '{"spec":{"suspend":false}}'
   kubectl --context <ctx> -n $NS get cronjob -o name | grep retention \
     | xargs -r kubectl --context <ctx> -n $NS patch -p '{"spec":{"suspend":false}}'
   # Argo CD machine: the ApplicationSet controller puts the sync policy back
   sudo kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=1
   ```

   Then sync the Application (Argo CD UI, or `argocd app sync <env> --core` on the Argo CD
   machine): it scales the APIs and BFFs back to the replicas of the values.

5. **Check**: `./scripts/verify.sh <ctx> <env> <domain>`, sign in on the Login front, open
   a project and a calendar. Run the backup CronJob once by hand so that the next snapshot
   is not 6 hours away:

   ```bash
   kubectl --context <ctx> -n $NS create job --from=cronjob/<env>-backup <env>-backup-after-restore
   ```

## Scenario B: the instance machine is lost

Order matters: the sealed-secrets controller generates a **new** key when it starts on a
cluster that has none, and the committed `secrets.yaml` then no longer decrypts. The old
key goes back **between phase 2 and phase 3**, because phase 3 is what makes Argo CD
deploy the controller. Phase 4 is **not** run: it would seal new passwords instead of the
ones the committed `secrets.yaml` (and the backups) use.

1. **New machine.** Create it in the instance's Scaleway project (same type and image as
   the lost one; `mairie360/Infra` describes it, never `terraform apply` without the team).
   Point the DNS records of the instance's domain to its public IP.
2. **Inventory.** In `ansible/inventory/hosts.yml`, change `ansible_host` of the instance
   to the new address. Keep its `wg_ip`, `org_id` and `env_name`.
3. **Phases 1, 1b and 2**, on the whole group (WireGuard needs every machine):

   ```bash
   cd ansible
   ansible-playbook playbooks/site.yml --limit '<org>_argocd:<org>_instances' --tags phase1,phase1b,phase2
   ```

4. **Sealing key back**, from the vault copy:

   ```bash
   scripts/restore-sealing-key-file.sh ~/.mairie360/sealing-keys/<org>-<env>.yaml root@<new machine>
   ```

   It applies the keys with the machine's k3s `kubectl` (nothing written on disk) and
   restarts the controller if one already runs.
5. **Phase 3** (and phase 5 if the group has the promotion runner):

   ```bash
   ansible-playbook playbooks/site.yml --limit '<org>_argocd:<org>_instances' --tags phase3
   ansible-playbook playbooks/site.yml --limit '<org>_argocd:<org>_instances' --tags phase5
   ```

   Argo CD re-registers the cluster and deploys the bootstrap layer (sealed-secrets,
   cert-manager, ingress controller), then the instance (on its own on dev; on staging and
   prod, sync the Application by hand).
6. **Secrets decrypt.** Every SealedSecret must be `Synced`:

   ```bash
   kubectl --context <ctx> -n mairie360-<env> get sealedsecrets
   ```

   A `no key could decrypt secret` status means the key file is older than the committed
   `secrets.yaml`: find a newer copy, or go to scenario D.
7. **Wait for the stack.** Postgres starts empty, Liquibase creates the schema and the
   admin account, the APIs start. Certificates come back from Let's Encrypt (mind its rate
   limits: 5 duplicate certificates a week per domain set).
8. **Restore the data**: scenario A from step 1. The backup bucket is outside the machine
   and its keys are in the decrypted `<env>-backup-secret`.
9. **Close**: `ansible-playbook playbooks/verify.yml`, then copy the files of
   `~/.mairie360` to the vault again if anything was resealed.

## Scenario C: the Argo CD machine is lost

The instances keep serving: only syncs and the promotion runner stop.

1. New machine, inventory updated (`ansible_host` of `<org>-argocd`), DNS if any.
2. `ansible-playbook playbooks/site.yml --limit '<org>_argocd:<org>_instances'` (every
   phase: the Argo CD machine holds no sealing key, phase 4 keeps every value already on
   the instances and only reseals them).
3. `ansible-playbook playbooks/verify.yml`, then check that each Application is `Synced`.

## Scenario D: the sealing key is lost too

The committed `secrets.yaml` of the instance is now useless. What still matters is
`RESTIC_PASSWORD` (vault): with it, the data comes back.

1. Run scenario B up to step 3, skip step 4, run phase 3 then **phase 4**, giving back
   the old `RESTIC_PASSWORD` (the role reads `~/.mairie360/restic-<org>-<env>.txt` when the
   instance has none: put the vault copy there first). Phase 4 generates new database,
   Redis and JWT secrets and asks for the external keys (Resend, Object Storage, backup
   bucket keys, admin e-mail).
2. Publish the new session key, then the secrets. Phase 4 runs `scripts/seal-secrets.sh`,
   which prints the new public key of Core's session key: put it in
   `global.jwt.publicKey` of the instance's `values.yaml` (the old block can go, its
   private key is lost), commit and push it, then commit and push the new `secrets.yaml`
   and let Argo CD deploy both. Without the new public key, every service refuses the
   tokens Core signs and nobody can sign in.
3. Restore the data (scenario A). The dump is restored with `--no-owner`, so the new
   database passwords do not matter.
4. Store the new sealing key and admin password in the vault. Every user must sign in
   again (new JWT keys).

## Quarterly rebuild drill

Proves the instance RTO (2 hours, `compliance/<org>/service-levels.yaml`) on a real machine:
**dev** is rebuilt from scratch with scenario B, timed, every quarter (deadline
`rebuild-drill` of `compliance/<org>/deadlines.yaml`, required by
`scripts/check-compliance.py`). Dev holds no mairie data and auto-syncs; tell the team
first, it is down during the drill.

1. **Before T0**: a backup of dev less than 6 hours old (`scripts/list-snapshots.sh`), the
   vault files of dev at hand (sealing key, `RESTIC_PASSWORD`), the new machine's Terraform
   change reviewed in `mairie360/Infra` (plan on its PR, apply with the team). Write down
   the number of users and projects of dev.
2. **T0, the loss**: power the dev machine **off** in the Scaleway console (do not delete
   it: it is the way back if the drill fails). Start the clock:

   ```bash
   drill() { echo "$(date -u +%FT%TZ) $*" | tee -a ~/rebuild-drill-$(date -u +%F).log; }
   drill "T0 dev machine off"
   ```

3. **Rebuild**: scenario B, steps 1 to 9, with `drill "<step>"` after each step (machine
   created, DNS, phases 1-2, sealing key, phase 3, secrets synced, stack up, data restored,
   verify.yml).
4. **T1, back**: `./scripts/verify.sh` passes, you can sign in on the Login front, the
   numbers of users and projects are the ones written down at step 1. `drill "T1 back"`.
   T1 - T0 is the measured RTO.
5. **Close**: delete the old machine (Terraform, `mairie360/Infra`), then in **one PR**: a
   row in the drill log below (date, T1 - T0, the slowest steps, what went wrong),
   `last_done` of `rebuild-drill` set to the date in `compliance/<org>/deadlines.yaml`, and
   the fixes of this runbook. Above 2 hours: a Jira ticket for the slowest step, and review
   the RTO with the team (`service-levels.yaml`, it is in the contract).

If the drill fails, power the old machine back on and point `ansible_host` and the DNS back
to it: dev is as it was at T0.

## Drill log

Rebuild drills record their measured time (T1 - T0) in the result.

A drill replays the risky steps on throwaway clusters, never on a real instance.

| Date | What was replayed | Result |
| --- | --- | --- |
| 2026-11-16 | Scenario B steps 4 to 6 on throwaway kind clusters (`ansible` `tests/mair_244_sealing_key_drill.sh`): a Secret sealed by the controller of cluster 1, the key saved the way phase 4 does, cluster 1 deleted, the key restored on cluster 2 with `restore-sealing-key-file.sh`, then the SealedSecret applied | Decrypts when the key is restored before the controller, and when it is restored after (the script restarts the controller). A cluster without the key does not decrypt it (`no key could decrypt secret`). |
| 2026-11-16 | `scripts/list-snapshots.sh` on a kind cluster with the rendered dev CronJob and a dummy `dev-backup-secret` (`restic version`, then `restic snapshots` against the unreachable dev bucket), plus `tests/scripts/mair_244_list_snapshots_test.sh` | The pod starts with the CronJob's image, keys and labels, prints restic's output and is deleted afterwards; no secret value is passed on the command line. |

The database part (backup then restore on a real cluster) is replayed by the e2e test of
the backup chart (`tests/e2e/restore.sh`), and on every instance each week by the restore
test (`charts/backup` README, "Weekly restore test").
