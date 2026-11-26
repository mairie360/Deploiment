#!/usr/bin/env bash
# MAIR-1185: seal-secrets.sh seals TEST_ACCOUNTS_PASSWORD (the external attack
# campaign test accounts) in <env>-database-secret as an argon2id hash, keeps it
# from the cluster, never generates it, and never seals it for prod.
# kubectl and kubeseal are stubbed like in mair_805_totp_key_test.sh.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0
ok()   { echo "  OK    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }

mkdir -p "$WORK/bin" "$WORK/root/scripts/lib" "$WORK/root/clusters/org/instances/env" "$WORK/root/clusters/org/instances/prod"
cp "$REPO/scripts/seal-secrets.sh" "$WORK/root/scripts/"
cp "$REPO/scripts/lib/secret-values.sh" "$WORK/root/scripts/lib/"
printf 'global:\n  domain: "env.example"\n' > "$WORK/root/clusters/org/instances/env/values.yaml"
printf 'global:\n  domain: "prod.example"\n' > "$WORK/root/clusters/org/instances/prod/values.yaml"

cat > "$WORK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# get secret NAME [--ignore-not-found] -o jsonpath={.data.KEY}
printf '%s\n' "$*" >> "$FAKE_CLUSTER.argv"
if [ "${KUBECTL_FAIL:-}" = 1 ]; then echo "connection refused" >&2; exit 1; fi
args=("$@"); name=""; key=""; ignore=0; create=0; literals=()
for ((i = 0; i < ${#args[@]}; i++)); do
  a="${args[$i]}"
  case "$a" in
    get) ;;
    create) create=1 ;;
    secret) [ "$create" = 1 ] || name="${args[$((i + 1))]}" ;;
    --ignore-not-found) ignore=1 ;;
    jsonpath=*) key="${a#jsonpath=\{.data.}"; key="${key%\}}" ;;
    --from-literal=*) literals+=("${a#--from-literal=}") ;;
    --from-file=*) f="${a#--from-file=}"; literals+=("${f%%=*}=$(cat "${f#*=}")") ;;
  esac
done
if [ "$create" = 1 ]; then
  # create secret generic NAME ...: the name follows "generic"
  for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = generic ] && name="${args[$((i + 1))]}"; done
  echo "kind: Secret"; echo "name: $name"
  for l in "${literals[@]}"; do echo "${l%%=*}: $(printf '%s' "${l#*=}" | base64 -w0)"; done
  exit 0
fi
f="$FAKE_CLUSTER/$name/$key"
if [ -f "$f" ]; then base64 -w0 < "$f"; exit 0; fi
[ -d "$FAKE_CLUSTER/$name" ] && exit 0
[ "$ignore" = 1 ] && exit 0
echo "Error from server (NotFound): secrets \"$name\" not found" >&2; exit 1
EOF
printf '#!/usr/bin/env bash\ncat\n' > "$WORK/bin/kubeseal"
chmod +x "$WORK/bin/kubectl" "$WORK/bin/kubeseal"

# Run seal-secrets.sh against the fake cluster; stdout+stderr in $WORK/out.
run() {
  (cd "$WORK/root" && PATH="$WORK/bin:$PATH" FAKE_CLUSTER="$WORK/cluster" \
    ADMIN_EMAIL=admin@example.org ADMIN_PASSWORD='$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA' \
    RESTIC_PASSWORD=restic ./scripts/seal-secrets.sh ctx org "${ENVNAME:-env}" "$@") > "$WORK/out" 2>&1
}
# TEST_ACCOUNTS_PASSWORD sealed in the database Secret of the env's secrets.yaml, decoded.
sealed_test() {
  awk -v n="name: ${1:-env}-database-secret" '$0 ~ n { f = 1 } f && /TEST_ACCOUNTS_PASSWORD:/ { print $2; exit }' \
    "$WORK/root/clusters/org/instances/${1:-env}/secrets.yaml" | base64 -d
}
HASH='$argon2id$v=19$m=19456,t=2,p=1$dGVzdA$dGVzdGhhc2g'

echo "== MAIR-1185 nothing passed, nothing on the cluster: no test accounts sealed"
rm -rf "$WORK/cluster"; mkdir -p "$WORK/cluster"
if run; then ok "seal-secrets.sh succeeds"; else fail "seal-secrets.sh failed: $(cat "$WORK/out")"; fi
if [ -z "$(sealed_test)" ]; then ok "no TEST_ACCOUNTS_PASSWORD is generated"; else fail "a TEST_ACCOUNTS_PASSWORD was sealed without being passed"; fi

echo "== MAIR-1185 a hash passed is sealed as-is and never printed"
rm -f "$WORK/root/clusters/org/instances/env/secrets.yaml"
if TEST_ACCOUNTS_PASSWORD="$HASH" run; then ok "seal-secrets.sh succeeds"; else fail "failed: $(cat "$WORK/out")"; fi
if [ "$(sealed_test)" = "$HASH" ]; then ok "the hash is sealed"; else fail "sealed '$(sealed_test)' instead of the hash"; fi
if grep -qF -- "$HASH" "$WORK/out"; then fail "the hash leaks to the output"; else ok "the hash is never printed"; fi

echo "== MAIR-1185 re-run and --rotate keep the hash of the cluster"
mkdir -p "$WORK/cluster/env-database-secret"
printf '%s' "$HASH" > "$WORK/cluster/env-database-secret/TEST_ACCOUNTS_PASSWORD"
for mode in "" --rotate; do
  rm -f "$WORK/root/clusters/org/instances/env/secrets.yaml"
  run $mode
  if [ "$(sealed_test)" = "$HASH" ]; then ok "${mode:-re-run}: same hash sealed again"; else fail "${mode:-re-run}: the hash was not kept"; fi
done

echo "== MAIR-1185 a plaintext on the cluster is dropped, not sealed"
printf 'plain-text' > "$WORK/cluster/env-database-secret/TEST_ACCOUNTS_PASSWORD"
rm -f "$WORK/root/clusters/org/instances/env/secrets.yaml"
run
if [ -z "$(sealed_test)" ]; then ok "a plaintext kept value is dropped"; else fail "a plaintext was sealed"; fi

echo "== MAIR-1185 prod: refused when passed, dropped when found on the cluster"
if TEST_ACCOUNTS_PASSWORD="$HASH" ENVNAME=prod run; then fail "prod accepted TEST_ACCOUNTS_PASSWORD"; else ok "prod refuses TEST_ACCOUNTS_PASSWORD"; fi
if grep -q "refused for prod" "$WORK/out"; then ok "the refusal says why"; else fail "no reason given: $(cat "$WORK/out")"; fi
mkdir -p "$WORK/cluster/prod-database-secret"
printf '%s' "$HASH" > "$WORK/cluster/prod-database-secret/TEST_ACCOUNTS_PASSWORD"
if ENVNAME=prod run; then ok "prod seals without the test accounts"; else fail "prod failed: $(cat "$WORK/out")"; fi
if [ -z "$(sealed_test prod)" ]; then ok "a value found on a prod cluster is not sealed again"; else fail "prod sealed TEST_ACCOUNTS_PASSWORD"; fi

exit "$FAILED"
