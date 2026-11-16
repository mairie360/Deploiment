#!/usr/bin/env bash
# =============================================================================
# Backup -> restore round trip (MAIR-240), run by run.sh once the stack is up.
#
# 1. writes a few rows in a table of the Mairie360 database,
# 2. runs the backup CronJob once (restic -> the S3 endpoint of s3.yaml),
# 3. damages the database: rows deleted, rows added that are not in the backup,
# 4. runs the restore Job rendered from the chart (backup.restore.enabled):
#    first aimed at the wrong database and at an unknown snapshot (it must
#    refuse and change nothing), then for real; the state before the restore
#    must have been saved as a pre-restore snapshot,
# 5. checks the database is back to the backed-up state, row for row, with
#    the same schema and role privileges (DROP SCHEMA public removes them).
#
# Needs K (kubectl with --context), CTX, NAMESPACE, RELEASE, ROOT and the
# HELM_VALUES array (the helm -f/--set flags of the install): run.sh sources
# this file.
# =============================================================================
set -euo pipefail

: "${K:?}" "${NAMESPACE:?}" "${RELEASE:?}" "${ROOT:?}"
DB_POD="$RELEASE-database-0"
step() { printf '\n\033[1m--> %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# psql as the superuser inside the database pod: `exec` does not go through
# the NetworkPolicies, and the password is the one of the pod's own env.
sql() {
  $K -n "$NAMESPACE" exec "$DB_POD" -- sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' _ "$1"
}
# restic snapshots of the database lineage, as JSON, read through a throwaway
# Job that gets the backup Secret and the repository like the backup Job.
snapshots_json() {
  local repo="s3:http://s3.s3.svc.cluster.local:7070/e2e-backups" db
  db="$(sql 'SELECT current_database()')"
  $K -n "$NAMESPACE" delete job e2e-restic-list --ignore-not-found >/dev/null
  $K -n "$NAMESPACE" apply -f - >/dev/null <<EOM
apiVersion: batch/v1
kind: Job
metadata: { name: e2e-restic-list }
spec:
  backoffLimit: 0
  template:
    metadata: { labels: { app.kubernetes.io/component: backup } }
    spec:
      restartPolicy: Never
      containers:
        - name: restic
          image: restic/restic:0.18.1
          args: ["snapshots", "--host", "$db", "--json"]
          envFrom: [ { secretRef: { name: $RELEASE-backup-secret } } ]
          env: [ { name: RESTIC_REPOSITORY, value: "$repo" }, { name: AWS_DEFAULT_REGION, value: us-east-1 } ]
EOM
  $K -n "$NAMESPACE" wait job/e2e-restic-list --for=condition=complete --timeout=3m >/dev/null \
    || { $K -n "$NAMESPACE" logs job/e2e-restic-list --tail=20 >&2 || true; fail "could not list the snapshots"; }
  $K -n "$NAMESPACE" logs job/e2e-restic-list
}
# restore_job <snapshot id> <confirmDatabase>: render the Job and apply it by hand.
restore_job() {
  $K -n "$NAMESPACE" delete job "$RELEASE-backup-restore" --ignore-not-found >/dev/null
  helm template "$RELEASE" "$ROOT/charts/mairie360-stack" -n "$NAMESPACE" \
    "${HELM_VALUES[@]}" \
    --set backup.restore.enabled=true --set "backup.restore.snapshotId=$1" \
    --set "backup.restore.confirmDatabase=$2" \
    -s charts/backup/templates/restore-job.yaml \
    | $K -n "$NAMESPACE" apply -f -
}
probe_rows() { sql "SELECT string_agg(id || ':' || label, ',' ORDER BY id) FROM mair240_restore_probe"; }
user_count() { sql "SELECT count(*) FROM users"; }
# Everything the API roles rely on in schema public: the schema ACL, the owner
# and the grants to other roles of every table / view / sequence (the owner's
# own entry is left out: an explicit {owner=arwdDxtm/owner} and a NULL ACL grant
# the same, and pg_dump restores one as the other), and what each
# *_api role may do. DROP SCHEMA public CASCADE removes all of it, the dump has
# to bring it back identical.
privileges() {
  sql "SELECT 'schema=' || coalesce(nspacl::text, 'none') || ' owner=' || pg_get_userbyid(nspowner)
         FROM pg_namespace WHERE nspname = 'public'
       UNION ALL
       SELECT 'object ' || relname || ' ' || relkind::text || ' owner=' || pg_get_userbyid(relowner) || ' acl=' || coalesce(nullif(array_to_string(ARRAY(SELECT a::text FROM unnest(relacl) a WHERE a::text NOT LIKE pg_get_userbyid(relowner) || '=%'), ','), ''), 'none')
         FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p', 'v', 'S', 'm')
       UNION ALL
       SELECT 'role ' || rolname || ' usage=' || has_schema_privilege(rolname, 'public', 'USAGE')
              || ' selectable=' || (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace
                                      AND c.relkind IN ('r', 'p') AND has_table_privilege(rolname, c.oid, 'SELECT'))
         FROM pg_roles WHERE rolname LIKE '%\_api' ORDER BY 1"
}

step "Write the reference data"
sql "DROP TABLE IF EXISTS mair240_restore_probe"
sql "CREATE TABLE mair240_restore_probe (id int PRIMARY KEY, label text NOT NULL)"
sql "INSERT INTO mair240_restore_probe SELECT g, 'row-' || g FROM generate_series(1, 25) g"
EXPECTED_PROBE="$(probe_rows)"
EXPECTED_USERS="$(user_count)"
EXPECTED_PRIVILEGES="$(privileges)"
[ "$(printf '%s\n' "$EXPECTED_PRIVILEGES" | grep -c '^role .* usage=true')" -ge 1 ] \
  || fail "no API role has USAGE on schema public before the backup: the privilege check would prove nothing"
echo "$EXPECTED_PRIVILEGES"
[ "$(sql 'SELECT count(*) FROM mair240_restore_probe')" = 25 ] || fail "reference table not filled"
echo "probe table: 25 rows, users: $EXPECTED_USERS"

step "Run the backup CronJob once"
$K -n "$NAMESPACE" delete job e2e-backup-run --ignore-not-found >/dev/null
$K -n "$NAMESPACE" create job e2e-backup-run --from="cronjob/$RELEASE-backup"
if ! $K -n "$NAMESPACE" wait job/e2e-backup-run --for=condition=complete --timeout=5m; then
  $K -n "$NAMESPACE" logs job/e2e-backup-run --all-containers --tail=60 || true
  fail "the backup Job did not complete"
fi

step "Damage the database"
sql "DELETE FROM mair240_restore_probe WHERE id <= 10"
sql "UPDATE mair240_restore_probe SET label = 'tampered' WHERE id > 20"
sql "INSERT INTO mair240_restore_probe VALUES (1000, 'not in the backup')"
[ "$(probe_rows)" != "$EXPECTED_PROBE" ] || fail "the damage had no effect, the test proves nothing"

step "Restore guards: the chart refuses an unsafe restore"
for unsafe in latest ""; do
  if helm template "$RELEASE" "$ROOT/charts/mairie360-stack" -n "$NAMESPACE" "${HELM_VALUES[@]}" \
       --set backup.restore.enabled=true --set "backup.restore.snapshotId=$unsafe" \
       --set backup.restore.confirmDatabase=x -s charts/backup/templates/restore-job.yaml >/dev/null 2>&1; then
    fail "the chart rendered a restore with snapshotId='$unsafe'"
  fi
done
if helm template "$RELEASE" "$ROOT/charts/mairie360-stack" -n "$NAMESPACE" "${HELM_VALUES[@]}" \
     --set backup.restore.enabled=true --set backup.restore.snapshotId=abcd1234 \
     -s charts/backup/templates/restore-job.yaml >/dev/null 2>&1; then
  fail "the chart rendered a restore without confirmDatabase"
fi

SNAPSHOT_ID="$(snapshots_json | jq -r '[.[] | select(.tags // [] | index("scheduled"))] | sort_by(.time) | last | .short_id')"
[ -n "$SNAPSHOT_ID" ] && [ "$SNAPSHOT_ID" != null ] || fail "no scheduled snapshot found"
echo "snapshot to restore: $SNAPSHOT_ID"
DB_NAME="$(sql 'SELECT current_database()')"

step "Restore guards: a Job aimed at another database changes nothing"
BEFORE_REFUSAL="$(probe_rows)"
restore_job "$SNAPSHOT_ID" "not-$DB_NAME"
$K -n "$NAMESPACE" wait "job/$RELEASE-backup-restore" --for=condition=failed --timeout=3m \
  || fail "the Job aimed at the wrong database did not fail"
$K -n "$NAMESPACE" logs "job/$RELEASE-backup-restore" --all-containers | grep -q "REFUSED" \
  || fail "the refusal is not in the Job logs"
[ "$(probe_rows)" = "$BEFORE_REFUSAL" ] || fail "the refused Job changed the database"

step "Restore guards: an unknown snapshot changes nothing"
restore_job "deadbeef" "$DB_NAME"
$K -n "$NAMESPACE" wait "job/$RELEASE-backup-restore" --for=condition=failed --timeout=3m \
  || fail "the Job with an unknown snapshot did not fail"
[ "$(probe_rows)" = "$BEFORE_REFUSAL" ] || fail "the Job with an unknown snapshot changed the database"

step "Restore: the Job rendered from the chart"
restore_job "$SNAPSHOT_ID" "$DB_NAME"
if ! $K -n "$NAMESPACE" wait "job/$RELEASE-backup-restore" --for=condition=complete --timeout=5m; then
  $K -n "$NAMESPACE" logs "job/$RELEASE-backup-restore" --all-containers --tail=60 || true
  fail "the restore Job did not complete"
fi
snapshots_json | jq -e '[.[] | select(.tags // [] | index("pre-restore"))] | length >= 1' >/dev/null \
  || fail "no pre-restore snapshot: the state before the restore was not saved"

step "The database is back to the backed-up state"
[ "$(probe_rows)" = "$EXPECTED_PROBE" ] || fail "probe rows differ: got '$(probe_rows)'"
[ "$(sql 'SELECT count(*) FROM mair240_restore_probe')" = 25 ] || fail "probe row count is not 25"
[ "$(user_count)" = "$EXPECTED_USERS" ] || fail "users: expected $EXPECTED_USERS, got $(user_count)"
[ "$(privileges)" = "$EXPECTED_PRIVILEGES" ] || {
  echo "privileges differ after the restore:" >&2
  diff <(printf '%s\n' "$EXPECTED_PRIVILEGES") <(privileges) >&2 || true
  fail "schema public privileges are not the ones of the backup"
}
echo "restore OK: 25 probe rows identical, $EXPECTED_USERS users, schema and role privileges identical"

sql "DROP TABLE mair240_restore_probe"
