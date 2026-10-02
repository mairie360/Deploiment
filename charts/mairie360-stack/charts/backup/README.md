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

**Known limit:** the same key pair writes snapshots and runs
`restic forget --prune`, so a compromised instance can delete its own
backups. Protect the bucket on the provider side (object lock / versioning
with a retention period longer than `retention.keepDaily`).

## Enabling it for an instance

1. Create an S3-compatible bucket for that instance (provider and bucket
   naming are an infra decision, not part of this repo) and an access-key
   pair scoped to it.
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
   ansible role generates it on the first run, then keeps it, and writes it
   to `~/.mairie360/restic-<org>-<env>.txt` (mode 600) on the workstation.
   Store that file in the team vault, like the sealed-secrets sealing key —
   losing it makes every existing backup permanently unreadable. To restore
   into a reinstalled instance, pass the old value back through
   `instance_secrets[<host>].restic_password`. When sealing by hand, read it
   from the cluster:
   ```bash
   kubectl -n mairie360-<env> get secret <env>-backup-secret \
     -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d
   ```
3. In `clusters/<org>/instances/<env>/values.yaml`:
   ```yaml
   backup:
     enabled: true
     schedule: "0 3 * * *"          # cron, evaluated in UTC
     s3:
       endpoint: "https://s3.<region>.example.com"
       bucket: "mairie360-<org>-<env>-backups"
       region: "<region>"
     retention:
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

## Keycloak (MAIR-231)

Set `backup.keycloak.enabled: true` on an instance where Keycloak is deployed
(`keycloak.enabled: true`, the default everywhere) to add a second
`pg_dump`/`restic backup` pass, right after the Mairie360 database, against
Keycloak's own PostgreSQL (`<release>-keycloak-db`). It authenticates with
`KEYCLOAK_DB_PASSWORD` from `<release>-keycloak-secret` (nothing new to seal)
and lands in the **same** S3 repository, tagged with its own `--host
keycloak-<db-name>` so it is a separate snapshot lineage from the Mairie360
database's, with its own retention. `charts/keycloak/templates/network-policy.yaml`
admits `app.kubernetes.io/component: backup` on `keycloak-db:5432` for this.

Sibling subcharts don't see each other's values, so this is independent from
the umbrella chart's `keycloak.enabled`: don't turn it on for an instance
without Keycloak. The restore Job (`templates/restore-job.yaml`) is not
wired up for the Keycloak dump yet — restoring it today means dumping the
snapshot by hand (`restic dump --host keycloak-<db-name> <snapshot> ... |
pg_restore` against `<release>-keycloak-db`), same connection details as
`charts/keycloak/templates/db-statefulset.yaml`.

## Restoring

`templates/restore-job.yaml` renders nothing unless `backup.restore.enabled`
is set, and carries no Argo CD hook annotation — so it must be applied by
hand, never left `true` in a values file an Argo CD Application tracks:

```bash
helm dependency build ./charts/mairie360-stack
helm template <release> ./charts/mairie360-stack -f <instance values file> \
  -s charts/backup/templates/restore-job.yaml \
  --set backup.restore.enabled=true \
  --set backup.restore.snapshotId=<snapshot-id-or-latest> \
  | kubectl --context <kube-context> -n mairie360-<env> apply -f -
```

List available snapshots first with a throwaway pod using the same image and
env as the CronJob (`AWS_*` / `RESTIC_*` from `<release>-backup-secret`):
`restic snapshots --host <db-name>`.

The restore Job runs `pg_restore --clean --if-exists --no-owner`: it drops
and recreates every object the dump contains against the *existing*
Postgres server (it does not create the server or the role, only the schema
and data), so the database ends up in the exact state it was in at backup
time. Delete the Job (`kubectl delete job <release>-backup-restore`) once
done — `ttlSecondsAfterFinished` also cleans it up automatically after an
hour.

## Verifying

`scripts/verify.sh` checks that the most recent backup Job succeeded. A
failed backup is also visible with:

```bash
kubectl --context <ctx> -n mairie360-<env> get jobs -l app.kubernetes.io/component=backup
```
