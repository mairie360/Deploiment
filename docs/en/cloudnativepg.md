# PostgreSQL on CloudNativePG: cutover and point-in-time recovery

The `database` subchart can run the Mairie360 PostgreSQL in two ways:

- **`statefulset`** (default): one Postgres pod from `ghcr.io/mairie360/database`, backed up once
  a day by the `backup` CronJob (`pg_dump` + restic). A lost or corrupted database goes back to
  the last dump: up to 24 hours of writes are lost.
- **`cnpg`**: a [CloudNativePG](https://cloudnative-pg.io) `Cluster` whose WAL is archived
  continuously to the instance's backup bucket by the Barman Cloud plugin, with a base backup
  every night. The database can be restored to any second between its first recovery point
  (the first base backup of the generation) and the last archived WAL segment, over at most
  the last 35 days, as long as the backups and the WAL archiving succeed
  (`ContinuousArchiving` condition of the Cluster).

French version: [`docs/fr/cloudnativepg.md`](../fr/cloudnativepg.md). The general disaster
recovery runbook is [`disaster-recovery.md`](disaster-recovery.md).

## How it fits together

| Piece | Where | What it does |
| --- | --- | --- |
| Operator + Barman Cloud plugin | `bootstrap/addons/cloudnative-pg` (namespace `cnpg-system`, one per instance machine) | Run the `Cluster`, archive WAL, take and restore backups. The plugin needs cert-manager, already on every instance. |
| `Cluster` `<release>-database-g<generation>` | `charts/database/templates/cnpg-cluster.yaml` | Postgres (official `ghcr.io/cloudnative-pg/postgresql` image, Debian bookworm like the StatefulSet's). Argo CD never prunes or deletes it (`Prune=false,Delete=false`). |
| `ObjectStore` `<release>-database-backups` | same file | `s3://<bucket>/cnpg/<cluster name>/`, keys of `<release>-backup-secret`, retention `35d`. |
| `ScheduledBackup` `<cluster>-daily` | same file | A base backup at 02:30 UTC, and one as soon as the Cluster is ready. |
| Client Service `<release>-database` | `charts/database/templates/service.yaml` | `engine` picks what it reaches: the StatefulSet's pod or the primary of the current generation. APIs, Liquibase, backup and retention keep the same host. |
| `<release>-database-superuser` | `scripts/seal-secrets.sh` | `kubernetes.io/basic-auth`, `postgres` and the `POSTGRES_PASSWORD` of `<release>-database-secret`, so every Job logs in the same way on both engines. |

The `pg_dump` + restic backup keeps running on both engines: it stays the long-term,
logical copy (and the one `backup.sealing` works on), the WAL archive is the fine-grained one.

**Why 35 days:** the backup bucket has a 30-day object lock in COMPLIANCE mode
(`mairie360/Infra`). The plugin deletes the objects older than its retention; with a retention
shorter than the lock, those deletions would fail.

**Generations:** CloudNativePG never restores in place, it bootstraps a new `Cluster` from the
backups. The chart names each Cluster after `database.cnpg.generation`; a restore bumps it, the
new Cluster recovers from the previous generation's folder of the bucket, and archives into its
own. The client Service follows the current generation.

## Before the first cutover of an instance

1. The operator runs on the machine. **Pending:** the AppSet `cloudnative-pg-appset.yaml` and
   its `projects.yaml` entries come in a follow-up PR, merged once this one has reached
   staging and prod (a new addon path must exist on every environment branch before an AppSet
   references it). Until that PR is merged and promoted, no instance can be cut over. The
   AppSet then deploys the operator to every instance, reading `bootstrap/addons/cloudnative-pg`
   at the machine's revision.

   ```bash
   kubectl -n cnpg-system get deploy        # cnpg-cloudnative-pg and barman-cloud: Available
   ```

2. `<release>-database-superuser` is sealed: re-run the instance's secrets (ansible
   `playbooks/secrets.yml`, or `scripts/seal-secrets.sh`), commit `secrets.yaml`.
   `scripts/check-instance-secrets.sh` (Promote) refuses an instance with `cnpg.enabled` and
   without that Secret.
3. The backup bucket and `<release>-backup-secret` exist (they already do on every tracked
   instance).
4. **GDPR records.** Enabling `database.cnpg` adds a second backup copy of the database to the
   bucket: WAL and base backups, kept 35 days, not sealed by `backup.sealing`, so an erasure
   only reaches it when it ages out. Before the cutover, list it in
   `compliance/<org>/retention.yaml` and `compliance/<org>/register.yaml` (and in the values'
   retention periods if `scripts/check-compliance.py` asks for it), in the same PR as commit 1.

## Cutover of an existing instance (StatefulSet → CloudNativePG)

Plan a maintenance window: the writers stop while the database is copied. Expect a few minutes
for a small database.

1. **Stop the writers.** If the instance's Application syncs on its own, stop the
   ApplicationSet controller first (on the group's Argo CD machine), or it puts the sync policy
   back within seconds, as in [`disaster-recovery.md`](disaster-recovery.md) step 2:

   ```bash
   sudo kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0
   sudo kubectl -n argocd patch application <env> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
   ```

   Then stop the APIs and suspend the retention CronJob, which writes through the client
   Service (its purge would otherwise run on the source during the copy):

   ```bash
   NS=mairie360-<env>
   kubectl -n $NS scale deploy -l app.kubernetes.io/component=api --replicas=0
   kubectl -n $NS get cronjob -o name | grep retention \
     | xargs -r kubectl -n $NS patch -p '{"spec":{"suspend":true}}'
   # Suspending does not stop a Job already running: wait until none is active.
   kubectl -n $NS get jobs -o json | jq -r '.items[] | select(.metadata.name | contains("retention"))
     | select((.status.active // 0) > 0) | .metadata.name'
   ```

2. **Commit 1, the copy.** In the instance's `values.yaml`:

   ```yaml
   database:
     cnpg:
       enabled: true
       bootstrap: import
       backup:
         s3:
           endpoint: https://s3.fr-par.scw.cloud
           bucket: <org>-backups-<env>
   ```

   Sync **only the new objects** (Argo CD → Sync → the `Cluster`, `ObjectStore`,
   `ScheduledBackup`, the `<release>-database-allow-cnpg` NetworkPolicy and the
   `<release>-database-superuser` Secret): a full sync would start the APIs again.
   CloudNativePG creates `<release>-database-g1` and copies the database and its roles
   from the StatefulSet (through `<release>-database-hl`). The client Service still points at
   the StatefulSet.

   ```bash
   kubectl -n mairie360-<env> get cluster <release>-database-g1     # STATUS: Cluster in healthy state
   kubectl -n mairie360-<env> get backup                             # the first base backup: completed
   ```

   Compare a few row counts (`users`, `projects`, `access_logs`) between the two pods
   (`kubectl exec <release>-database-0` and `kubectl exec <release>-database-g1-1`, `psql -U postgres -d <db>`).

3. **Commit 2, the switch.** Add `engine: cnpg` under `database`. Sync: the Liquibase Job runs
   against the new database (it re-applies the API roles' passwords), the client Service
   reaches the new primary, Argo CD scales the APIs back. Resume the retention CronJob
   (`"suspend":false`), so it runs on the new database, scale the ApplicationSet controller
   back to 1 if you stopped it (it puts the sync policy back), and run `scripts/verify.sh`.

   **Going back** at this point is setting `engine: statefulset` again: the StatefulSet is
   still there, but everything written since the switch is only in the Cluster.

4. **Commit 3, a few days later.** `statefulset.enabled: false`. Keep `bootstrap: import`: the
   operator only reads it when it creates a Cluster, and removing it would only show a diff.
   It is only right while that Cluster exists: after the loss of the machine, see
   **Rebuilt machine** below before the first sync.
   The StatefulSet's volume is kept; delete it once you no longer want the way back:

   ```bash
   kubectl -n mairie360-<env> delete pvc data-<release>-database-0
   ```

A **new** instance starts directly with `cnpg.enabled: true`, `engine: cnpg`,
`statefulset.enabled: false` and the default `bootstrap: initdb` (empty database, created for
Liquibase).

## Point-in-time recovery

1. **Pick the moment** just before the damage, as an RFC 3339 timestamp with its zone
   (`2026-11-20T09:30:00+01:00`). Check it is covered:

   ```bash
   kubectl -n mairie360-<env> get backup --sort-by=.status.startedAt   # base backups
   kubectl -n mairie360-<env> get cluster <release>-database-g<N> \
     -o jsonpath='{.status.firstRecoverabilityPoint}{"\n"}'
   ```

2. **Stop the writers** as for the cutover (auto-sync off, APIs at 0), so nothing more is
   written to generation N.
3. **One commit** in the instance's `values.yaml`:

   ```yaml
   database:
     cnpg:
       generation: <N+1>
       bootstrap: recovery
       recovery:
         targetTime: "2026-11-20T09:30:00+01:00"   # "" = replay every archived WAL
   ```

   Sync only the new `Cluster`, its `ScheduledBackup` and the `<release>-database` Service.
   CloudNativePG creates `<release>-database-g<N+1>` from the base backup before that moment
   and replays the WAL up to it; the client Service already selects it (no endpoint until the
   recovery is done). Generation N keeps running, untouched: Argo CD
   never deletes a Cluster.
4. **Check** the data, then sync everything (Liquibase, the APIs come back), re-enable
   auto-sync, run `scripts/verify.sh`. Then delete the old
   generation by hand (its archive stays in the bucket until the lock expires; delete
   `s3://<bucket>/cnpg/<release>-database-g<N>/` afterwards if you want the space back):

   ```bash
   kubectl -n mairie360-<env> delete cluster <release>-database-g<N>
   ```

Keep `bootstrap: recovery` in the values afterwards, for the same reason as `import`.

## Rebuilt machine

After the loss of an instance machine, the bucket still holds the WAL archive and the base
backups of generation N, but a fresh cluster would create `<release>-database-g<N>` from the
values: with `bootstrap: import` its source (`<release>-database-hl`) no longer exists once
`statefulset.enabled: false`, and with `initdb` it would start empty. Before the instance's
first sync (ansible phase 3 of [`disaster-recovery.md`](disaster-recovery.md), no phase 4),
commit a recovery into a new generation:

```yaml
database:
  cnpg:
    generation: <N+1>
    bootstrap: recovery
    recovery:
      fromGeneration: <N>
      targetTime: ""        # replay every archived WAL
```

The operator must already run on the new machine (its AppSet). Then follow **Point-in-time
recovery** from step 4 (check, sync, verify). The dump restore of the disaster-recovery
runbook is only needed when the bucket itself is lost.
A restore from an older generation than N sets `recovery.fromGeneration`.

The restic dump (`backup.restore.*`, `disaster-recovery.md` scenario A) still works on a
CloudNativePG instance: it restores a whole day, into the current generation.

## Limits

- One instance per Cluster (`cnpg.instances: 1`), like the machines: no failover yet. A
  replica only needs `instances: 2` and the room for it on the machine.
- The WAL archive lives in the same bucket as the dumps: losing the bucket's key pair stops
  both until it is resealed.
- Not tried yet on a real instance: the checksum headers of the plugin's S3 client against
  Scaleway's object lock. Watch the first `Backup` and `kubectl -n mairie360-<env> get cluster`
  (`ContinuousArchiving` condition) after the cutover of dev.
