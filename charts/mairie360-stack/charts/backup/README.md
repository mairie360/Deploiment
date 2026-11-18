# backup

CronJob that pipes `pg_dump -Fc` straight into `restic backup --stdin`, so the
dump never touches a local disk. restic gives encryption at rest, dedup, and
retention (`restic forget --prune`) against an S3-compatible bucket outside
the instance's machine — see [MAIR-119](https://mairie-360.atlassian.net/browse/MAIR-119)
for the rationale (a single-node k3s cluster's local-path PVC is not a backup
target).

The Job runs as uid 70 (the `postgres:alpine` user) on a read-only root
filesystem; restic is copied by an initContainer from the pinned
`restic/restic` image (`restic.image`), not installed at every run
(MAIR-414). The restore Job runs `pg_restore --single-transaction
--exit-on-error`: a failed restore rolls back instead of leaving a half-loaded
database.

The same key pair writes snapshots and runs `restic forget --prune`, so the
bucket itself must refuse deletions: the instance buckets
`<org>-backups-<env>` are created by
[`mairie360/Infra`](https://github.com/mairie360/Infra) (MAIR-618) versioned
and locked in **COMPLIANCE mode for 30 days**. A prune (or a stolen key) only
adds delete markers; every version of the last 30 days stays restorable
(`restic` >= 0.13 sends the Content-MD5 object lock requires). To restore
a snapshot pruned by mistake, roll the bucket objects back to their previous
version before running restic.

## Enabling it for an instance

1. Add the instance to `orgs/<org>/` of `mairie360/Infra`: its apply
   creates the locked bucket `<org>-backups-<env>` (MAIR-618). The access-key
   pair must reach that bucket only.
2. Seal `<release>-backup-secret` with the ansible repo (phase 4, which runs
   `scripts/seal-secrets.sh` on the group's Argo CD machine), then commit the
   `secrets.yaml` it writes into this checkout:
   ```bash
   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
     ansible-playbook playbooks/secrets.yml --limit <instance host>
   ```
   Once `backup.enabled` is true (step 3), later runs prompt for the key pair
   instead when it is neither exported nor already sealed.
   `RESTIC_PASSWORD` (the repository encryption key) is not an input: the
   ansible role generates it on the first run, then keeps it, and stores it
   in the team vault, Scaleway Secret Manager (`/<org>/<env>/restic-password`,
   MAIR-617), like the sealed-secrets sealing keys — losing it makes every
   existing backup permanently unreadable. To restore into a reinstalled
   instance, the role reads it back from the vault (or pass it through
   `instance_secrets[<host>].restic_password`). When sealing by hand, read it
   from the cluster:
   ```bash
   kubectl -n mairie360-<env> get secret <env>-backup-secret \
     -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d
   ```
3. In `clusters/<org>/instances/<env>/values.yaml`:
   ```yaml
   backup:
     enabled: true
     schedule: "0 */6 * * *"        # cron, evaluated in UTC (every 6 h, MAIR-630)
     s3:
       endpoint: "https://s3.<region>.example.com"
       bucket: "<org>-backups-<env>"   # created by mairie360/Infra
       region: "<region>"
     retention:
       keepHourly: 8                # the last 8 runs = 2 days
       keepDaily: 7
       keepWeekly: 4
       keepMonthly: 6
   ```
4. Once `egressDefaultDeny` is turned on for that instance, add the S3
   endpoint to `global.networkPolicy.egressAllowCIDRs` — the backup pod's
   only network need besides Postgres (already allowed by
   `charts/database/templates/network-policy.yaml`) is that bucket.

Argo CD picks up the change on the next sync; there is no hook, so the
CronJob is created/updated like any other resource.

## Sealed backups: a key per user (MAIR-500)

`backup.sealing.enabled` turns the backup into crypto-shredding: an erased user becomes unreadable
in every backup taken before the erasure, without anything being deleted from a backup.

1. A native sidecar (`scratch-db`, Postgres on `127.0.0.1` only, emptyDir) receives a copy of the
   live database (`copy`: `pg_dump | pg_restore`). The live database is only read.
2. `seal` (mairie360/Compliance_API image, `/app/compliance-backup seal`) reads the inventory of the
   deployed schema (`/gdpr/inventory.yaml` of the `liquibase-migrations` image, `inventoryImage.tag`
   = the instance's `liquibase.image.tag`) and, for each user, moves the personal values the
   erasure clears into `users/<id>.json`, encrypted with AES-256-GCM under a fresh data key that is
   only stored wrapped by the user's key in Scaleway Key Manager. The values are replaced by
   placeholders in the copy.
3. `backup` dumps the sealed copy into `/work` and runs `restic backup` on `/work`: the dump and the
   sealed users form **one** snapshot (tags `scheduled`, `sealed`), encrypted with the instance key
   (`RESTIC_PASSWORD`, outside the backup). Retention (`restic forget`) is unchanged and follows
   `compliance/<org>/retention.yaml` (MAIR-294).

Erasure: compliance-api destroys the user's key in Key Manager (`global.compliance.keyManager`,
`SCW_SECRET_KEY` of the compliance secret). No backup is modified; the user's wrapped data keys can
no longer be decrypted.

Restore (`restore.enabled`, below): with sealing on, the restore Job runs `restic restore` of the
snapshot, `pg_restore` of the dump, then `compliance-backup unseal env /work`: every user whose key
still exists comes back, erased ones stay anonymized (placeholders).

Before turning it on: a Key Manager in the instance's Scaleway project
(`global.compliance.keyManager.projectId`), an API key with Key Manager rights sealed as
`SCW_SECRET_KEY` in `<release>-backup-secret` (`BACKUP_SCW_SECRET_KEY=... scripts/seal-secrets.sh`)
and one allowed to delete keys in `<release>-compliance-secret` (`COMPLIANCE_SCW_SECRET_KEY`),
`sealing.image.tag` (a compliance-api release with `compliance-backup`) and `sealing.inventoryImage.tag`.
Size `sealing.scratchSize` / `workSize` for a copy of the database. The pod needs Kubernetes 1.29+
(native sidecars).

## Restoring

`templates/restore-job.yaml` renders nothing unless `backup.restore.enabled`
is set, and carries no Argo CD hook annotation — so it must be applied by
hand, never left `true` in a values file an Argo CD Application tracks:

```bash
kubectl config current-context        # must be the cluster of the instance to restore
helm dependency build ./charts/mairie360-stack
helm template <release> ./charts/mairie360-stack -f <instance values file> \
  -s charts/backup/templates/restore-job.yaml \
  --set backup.restore.enabled=true \
  --set backup.restore.snapshotId=<exact-snapshot-id> \
  --set backup.restore.confirmDatabase=<POSTGRES_DB of the database to replace> \
  | kubectl --context <kube-context> -n mairie360-<env> apply -f -
```

List the snapshots first with `scripts/list-snapshots.sh <kube-context>
<env>`: a throwaway pod using the same image and env as the CronJob (`AWS_*` /
`RESTIC_*` from `<release>-backup-secret`); extra arguments go to restic, e.g.
`snapshots --host <db-name>`. The chart refuses to render without an exact
snapshot id (`latest` is refused) and without `confirmDatabase`.

Stop the APIs and BFFs, the backup and retention CronJobs (and Argo CD's
automated sync, which would scale them back) before applying the Job, and
start them again afterwards: the full sequence, and how to rebuild a lost
machine before restoring, is in the disaster-recovery runbook,
`docs/en/disaster-recovery.md` at the root of this repository.

The Job checks everything before it changes anything, and stops otherwise:

1. `confirmDatabase` is the database the pod is connected to;
2. the snapshot exists and its archive is readable (`pg_restore --list`);
3. the current state is saved as a `pre-restore` snapshot (not with
   `sealing`: that copy would hold unsealed personal data, the scheduled
   sealed backup is the safety net there). A restore of the wrong snapshot
   can then be undone by restoring the `pre-restore` one.

Then it drops schema `public` and loads the dump back, in one transaction
(`BEGIN; DROP SCHEMA public CASCADE; CREATE SCHEMA public …`, then the dump as
SQL through `pg_restore -f -`, `COMMIT` only once `pg_restore` finished and
`public.users` is not empty) against the *existing* Postgres server (it does
not create the server or the role, only the schema and data), so the database
ends up in the exact state it was in at backup time, or untouched when
anything fails. It does not use `pg_restore --clean`: that fails on
partitioned tables (`cannot drop inherited constraint
access_logs_default_pkey`, found by the backup/restore e2e test, MAIR-240).
Everything in schema `public` is replaced; only Liquibase edits it, so
nothing outside the dump is lost, but everything written after the snapshot is.

**What a restore cannot give back.** Backups run every 6 hours: up to 6 hours of
writes are lost, and the chart has no point-in-time recovery or failover.
Redis (the JWT revocation list) is not restored by this Job.

Delete the Job (`kubectl delete job <release>-backup-restore`) once done —
`ttlSecondsAfterFinished` also cleans it up automatically after an hour.

## Verifying

`scripts/verify.sh` checks that the most recent backup Job succeeded. A
failed backup is also visible with:

```bash
kubectl --context <ctx> -n mairie360-<env> get jobs -l app.kubernetes.io/component=backup
```
