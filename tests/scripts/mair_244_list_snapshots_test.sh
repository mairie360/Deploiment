#!/usr/bin/env bash
# MAIR-244: scripts/list-snapshots.sh lists the restic snapshots of an instance
# through a throwaway pod built from the instance's own backup CronJob (the one
# the chart renders for dev), so it reaches the bucket with the CronJob's keys
# and labels, without any secret leaving the cluster. A fake kubectl serves the
# rendered CronJob and records the pod it is asked to run, the exec of restic in
# it, and its deletion.
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
    [ "${RUN_FAILS:-}" = 1 ] && exit 1
    for a in "$@"; do case "$a" in --overrides=*) printf '%s' "${a#--overrides=}" > "$WORK/overrides.json" ;; esac; done ;;
  *" wait --for=condition=Ready pod/"*) [ "${NOT_READY:-}" = 1 ] && exit 1; : ;;
  *" exec "*" -c restic -- restic "*) echo "restic output" ;;
  *" delete pod "*) : ;;
  *) exit 3 ;;
esac
SH
chmod +x "$WORK/kubectl"
export WORK KUBECTL="$WORK/kubectl"

# 1. Default: `restic snapshots` in a pod shaped like the CronJob.
rm -f "$WORK/calls" "$WORK/overrides.json"
"$SCRIPT" mairie360-dev dev > "$WORK/out" 2>&1 && ok "exit 0" || fail "exit code: $(cat "$WORK/out")"
grep -q -- "--context mairie360-dev -n mairie360-dev run dev-backup-snapshots-[0-9a-f]\{8\} --quiet --restart=Never --image=restic/restic:" "$WORK/calls" \
  && ok "throwaway pod in mairie360-dev, restic image" || fail "run call: $(cat "$WORK/calls")"
grep -q "restic output" "$WORK/out" && ok "restic's output is printed" || fail "output: $(cat "$WORK/out")"
# restic starts only once the pod is Ready, through exec (no output lost before an attach).
python3 - "$WORK/calls" <<'PY' && ok "wait Ready, then exec restic, then delete the pod" || fail "call order: $(cat "$WORK/calls")"
import re, sys
calls = open(sys.argv[1]).read().splitlines()
idx = lambda pat: next(i for i, c in enumerate(calls) if re.search(pat, c))
run, wait, ex, rm = idx(r" run "), idx(r" wait --for=condition=Ready pod/dev-backup-snapshots-"), idx(r" exec dev-backup-snapshots-[0-9a-f]{8} -c restic -- restic snapshots --no-cache$"), idx(r" delete pod dev-backup-snapshots-")
assert run < wait < ex < rm, calls
PY
python3 - "$WORK/overrides.json" "$WORK/cronjob.json" <<'PY' && ok "pod copies the CronJob's labels, security, pull secret and restic env" || fail "overrides"
import json, sys
o = json.load(open(sys.argv[1]))
t = json.load(open(sys.argv[2]))["spec"]["jobTemplate"]["spec"]["template"]
c = o["spec"]["containers"][0]
assert c["command"] == ["sh", "-c", "while :; do sleep 30; done"] and "args" not in c, c
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
rm -f "$WORK/calls"
"$SCRIPT" mairie360-dev dev snapshots --host keycloak-keycloak --json > /dev/null 2>&1
grep -q -- "-c restic -- restic snapshots --host keycloak-keycloak --json --no-cache$" "$WORK/calls" \
  && ok "restic arguments passed through" || fail "exec call: $(grep exec "$WORK/calls")"

# 2b. A pod that never gets Ready: error, no restic, pod deleted anyway.
rm -f "$WORK/calls"
if NOT_READY=1 "$SCRIPT" mairie360-dev dev > /dev/null 2>&1; then fail "succeeded without a Ready pod"; else ok "fails when the pod is not Ready"; fi
grep -q " exec " "$WORK/calls" && fail "restic ran in a pod that was not Ready" || ok "no restic before Ready"
grep -q " delete pod dev-backup-snapshots-" "$WORK/calls" && ok "pod deleted on the error path" || fail "pod left behind: $(cat "$WORK/calls")"

# 2c. A pod name already taken (another operator): fails without deleting that pod.
rm -f "$WORK/calls"
if RUN_FAILS=1 "$SCRIPT" mairie360-dev dev > /dev/null 2>&1; then fail "succeeded when the pod was not created"; else ok "fails when the pod cannot be created"; fi
grep -q " delete pod " "$WORK/calls" && fail "deleted a pod it did not create" || ok "no deletion of a pod it did not create"

# 3. No CronJob (backup disabled): clear error, no pod.
rm -f "$WORK/calls"
if NO_CRONJOB=1 "$SCRIPT" mairie360-dev dev > "$WORK/out" 2>&1; then fail "accepted an instance without backup"; else
  grep -q "backup.enabled" "$WORK/out" && ok "instance without backup refused" || fail "error message: $(cat "$WORK/out")"; fi
grep -q " run " "$WORK/calls" && fail "pod started without a CronJob" || ok "no pod without a CronJob"

# 4. Usage.
"$SCRIPT" mairie360-dev > /dev/null 2>&1; [ $? -eq 2 ] && ok "usage error without an env" || fail "usage exit code"

[ "$FAILED" -eq 0 ] && echo "OK" || { echo "FAILED"; exit 1; }
