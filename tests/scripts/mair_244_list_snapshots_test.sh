#!/usr/bin/env bash
# MAIR-244: scripts/list-snapshots.sh lists the restic snapshots of an instance
# through a throwaway pod built from the instance's own backup CronJob (the one
# the chart renders for dev), so it reaches the bucket with the CronJob's keys
# and labels, without any secret leaving the cluster. A fake kubectl serves the
# rendered CronJob and records the pod it is asked to run.
# Needs helm (dependencies built, as in CI), jq and python3 with PyYAML.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/list-snapshots.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0
ok()   { echo "  OK    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }

helm template dev "$ROOT/charts/mairie360-stack" \
  -f "$ROOT/clusters/mairie360/instances/dev/values.yaml" \
  -s charts/backup/templates/cronjob.yaml > "$WORK/cronjob.yaml" || { echo "helm template failed"; exit 1; }
python3 -c 'import json,sys,yaml; print(json.dumps(next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d)))' \
  "$WORK/cronjob.yaml" > "$WORK/cronjob.json"

cat > "$WORK/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK/calls"
case "$*" in
  *"get cronjob dev-backup -o json") [ "${NO_CRONJOB:-}" = 1 ] && exit 1; cat "$WORK/cronjob.json" ;;
  *" run "*)
    for a in "$@"; do case "$a" in --overrides=*) printf '%s' "${a#--overrides=}" > "$WORK/overrides.json" ;; esac; done ;;
  *) exit 3 ;;
esac
SH
chmod +x "$WORK/kubectl"
export WORK KUBECTL="$WORK/kubectl"

# 1. Default: `restic snapshots` in a pod shaped like the CronJob.
rm -f "$WORK/calls" "$WORK/overrides.json"
"$SCRIPT" mairie360-dev dev > "$WORK/out" 2>&1 && ok "exit 0" || fail "exit code: $(cat "$WORK/out")"
grep -q -- "--context mairie360-dev -n mairie360-dev run dev-backup-snapshots-[0-9]* --rm -i --quiet --restart=Never --image=restic/restic:" "$WORK/calls" \
  && ok "throwaway pod in mairie360-dev, removed on exit, restic image" || fail "run call: $(cat "$WORK/calls")"
python3 - "$WORK/overrides.json" "$WORK/cronjob.json" <<'PY' && ok "pod copies the CronJob's labels, security, pull secret and restic env" || fail "overrides"
import json, sys
o = json.load(open(sys.argv[1]))
t = json.load(open(sys.argv[2]))["spec"]["jobTemplate"]["spec"]["template"]
c = o["spec"]["containers"][0]
assert c["args"] == ["snapshots", "--no-cache"], c["args"]
assert o["metadata"]["labels"] == t["metadata"]["labels"]
assert o["metadata"]["labels"]["app.kubernetes.io/component"] == "backup"
assert o["spec"]["securityContext"] == t["spec"]["securityContext"]
assert o["spec"]["imagePullSecrets"] == t["spec"]["imagePullSecrets"]
assert o["spec"]["automountServiceAccountToken"] is False
names = [e["name"] for e in c["env"]]
assert sorted(names) == sorted(["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_DEFAULT_REGION",
                                "RESTIC_PASSWORD", "RESTIC_REPOSITORY", "HOME"]), names
# Secrets stay references to the cluster's Secret, never values.
for e in c["env"]:
    if e["name"] in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "RESTIC_PASSWORD"):
        assert e["valueFrom"]["secretKeyRef"]["name"] == "dev-backup-secret", e
        assert "value" not in e
# No Postgres credential in a pod that only reads the bucket.
assert not any(n.startswith("PG") or n.startswith("KEYCLOAK_") for n in names)
assert c["securityContext"]["readOnlyRootFilesystem"] is True
PY

# 2. Restic arguments are passed through.
rm -f "$WORK/overrides.json"
"$SCRIPT" mairie360-dev dev snapshots --host keycloak-keycloak --json > /dev/null 2>&1
[ "$(jq -c '.spec.containers[0].args' "$WORK/overrides.json")" = '["snapshots","--host","keycloak-keycloak","--json","--no-cache"]' ] \
  && ok "restic arguments passed through" || fail "args: $(jq -c '.spec.containers[0].args' "$WORK/overrides.json")"

# 3. No CronJob (backup disabled): clear error, no pod.
rm -f "$WORK/calls"
if NO_CRONJOB=1 "$SCRIPT" mairie360-dev dev > "$WORK/out" 2>&1; then fail "accepted an instance without backup"; else
  grep -q "backup.enabled" "$WORK/out" && ok "instance without backup refused" || fail "error message: $(cat "$WORK/out")"; fi
grep -q " run " "$WORK/calls" && fail "pod started without a CronJob" || ok "no pod without a CronJob"

# 4. Usage.
"$SCRIPT" mairie360-dev > /dev/null 2>&1; [ $? -eq 2 ] && ok "usage error without an env" || fail "usage exit code"

[ "$FAILED" -eq 0 ] && echo "OK" || { echo "FAILED"; exit 1; }
