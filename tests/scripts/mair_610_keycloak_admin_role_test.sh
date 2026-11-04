#!/usr/bin/env bash
# MAIR-610: scripts/keycloak-admin-role.sh gives an existing realm the
# composites of charts/keycloak `realm.roles[].clientComposites`, read from
# the rendered realm ConfigMap: `Admin` includes the realm-management user
# roles (manage-users, view-users, query-users, query-groups, view-events) and
# nothing else, a missing role is created first, the admin password only goes
# through kubectl exec's stdin and KC_CLI_PASSWORD (never kcadm's arguments in
# the pod), and a ConfigMap without composites stops it.
# kubectl is stubbed: `get secret` / `get configmap` answer from fixtures,
# `exec` runs the in-pod script with a fake kcadm.sh that logs its arguments.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0
ok()   { echo "  OK    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
mkdir -p "$WORK/bin"

# The realm the chart renders for dev, as the ConfigMap Argo CD synced.
helm template r "$REPO/charts/mairie360-stack" -f "$REPO/clusters/mairie360/instances/dev/values.yaml" \
  --show-only charts/keycloak/templates/realm-configmap.yaml \
  | python3 -c 'import sys, yaml, json; print(json.dumps(yaml.safe_load(sys.stdin)))' > "$WORK/realm.json"

cat > "$WORK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# exec: runs the script the real one sends to the pod (sh -c SCRIPT USER ARGS),
# with the fake kcadm.sh below in place of /opt/keycloak/bin/kcadm.sh.
args=("$@")
case " $* " in
  *" get secret "*) printf 'admin-pass' | base64 -w0; exit 0 ;;
  *" get configmap "*) cat "$REALM_CM"; exit 0 ;;
esac
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = "--" ] && break; done
script="${args[$((i + 3))]//\/opt\/keycloak\/bin\/kcadm.sh/$FAKE_KCADM}"
exec sh -c "$script" "${args[@]:$((i + 4))}"
EOF
# kcadm.sh in the pod: logs its arguments (without --config FILE), refuses a
# login without KC_CLI_PASSWORD, and logs what it reads with -f -.
cat > "$WORK/bin/kcadm.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = config ]; then
  printf '%s\n' "$*" >> "$WORK_LOG.login"
  [ "${KC_CLI_PASSWORD:-}" = admin-pass ] || exit 1
  exit 0
fi
a=("$@"); line="${a[*]:0:${#a[@]}-2}"
printf '%s\n' "$line" >> "$WORK_LOG.argv"
case " $* " in *" -f - "*) cat >> "$WORK_LOG.stdin"; echo >> "$WORK_LOG.stdin" ;; esac
case "$line" in
  "get roles/Admin "*) [ "${ROLE_EXISTS:-1}" = 1 ] || exit 1; echo '{"name":"Admin"}' ;;
  get-roles*) echo '[{"name":"view-users"},{"name":"manage-users"}]' ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/kubectl" "$WORK/bin/kcadm.sh"

run() {
  rm -f "$WORK/log.argv" "$WORK/log.stdin" "$WORK/log.login"
  PATH="$WORK/bin:$PATH" WORK_LOG="$WORK/log" REALM_CM="${CM:-$WORK/realm.json}" FAKE_KCADM="$WORK/bin/kcadm.sh" \
    "$REPO/scripts/keycloak-admin-role.sh" ctx dev > "$WORK/out" 2>&1
}

echo "== MAIR-610 keycloak-admin-role.sh"
run; rc=$?
[ "$rc" = 0 ] && ok "runs against an existing role" || { fail "exit $rc"; cat "$WORK/out"; }
grep -qx 'add-roles -r mairie360 --rname Admin --cclientid realm-management --rolename manage-users --rolename view-users --rolename query-users --rolename query-groups --rolename view-events' "$WORK/log.argv" \
  && ok "Admin gets exactly the realm-management user roles" || { fail "add-roles call"; cat "$WORK/log.argv"; }
grep -q 'manage-realm\|manage-clients\|realm-admin' "$WORK/log.argv" && fail "a realm-wide role is added" || ok "no realm-wide role (manage-realm, manage-clients, realm-admin)"
[ "$(grep -c '^add-roles' "$WORK/log.argv")" = 1 ] && ok "only Admin is composite" || fail "add-roles called for another role"
grep -q '^create roles' "$WORK/log.argv" && fail "creates an existing role" || ok "an existing role is not recreated"
grep -q 'admin-pass' "$WORK/log.argv" "$WORK/log.login" && fail "password on a kcadm command line" || ok "password never on a kcadm command line, in the pod either"
grep -q -- '--password' "$WORK/log.login" && fail "kcadm login with --password" || ok "kcadm logs in with KC_CLI_PASSWORD"
grep -q '^config credentials --config .* --server http://localhost:8080 --realm master --user admin$' "$WORK/log.login" \
  && ok "master admin session on the pod's local port" || { fail "login call"; cat "$WORK/log.login"; }
grep -q 'role Admin includes realm-management: manage-users, view-users' "$WORK/out" && ok "prints the composites" || fail "no summary"

ROLE_EXISTS=0 run; rc=$?
[ "$rc" = 0 ] && grep -q '^create roles -r mairie360 -f -' "$WORK/log.argv" && grep -q '{"name":"Admin","description":"System administrator"}' "$WORK/log.stdin" \
  && ok "a missing Admin role is created, then made composite" || { fail "missing role (exit $rc)"; cat "$WORK/log.argv"; }

python3 - "$WORK/realm.json" > "$WORK/old.json" <<'EOF'
import json, sys
cm = json.load(open(sys.argv[1]))
k = next(iter(cm["data"]))
realm = json.loads(cm["data"][k])
for r in realm["roles"]["realm"]:
    r.pop("composites", None); r.pop("composite", None)
cm["data"][k] = json.dumps(realm)
print(json.dumps(cm))
EOF
CM="$WORK/old.json" run; rc=$?
[ "$rc" != 0 ] && grep -q 'sync the chart version with MAIR-610 first' "$WORK/out" && [ ! -s "$WORK/log.argv" ] \
  && ok "a ConfigMap without composites stops before any kcadm call" || fail "old ConfigMap (exit $rc)"

exit "$FAILED"
