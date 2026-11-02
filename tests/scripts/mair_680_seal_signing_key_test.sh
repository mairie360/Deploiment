#!/usr/bin/env bash
# MAIR-680 (audit A1): seal-secrets.sh gives each instance one Ed25519 key
# pair for the session tokens. The private key is sealed alone in
# <env>-jwt-signing-secret (core-api only), generated when the cluster has
# none and never replaced afterwards (not even by --rotate, not on a failed
# read); the public half is printed for global.jwt.publicKey, never the
# private key.
# kubectl and kubeseal are stubbed: `get secret` answers from $FAKE_CLUSTER
# (one file per Secret key), `create secret` prints its literals base64-encoded
# and kubeseal passes them through, so secrets.yaml shows what would be sealed.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0
ok()   { echo "  OK    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }

mkdir -p "$WORK/bin" "$WORK/root/scripts/lib" "$WORK/root/clusters/org/instances/env"
cp "$REPO/scripts/seal-secrets.sh" "$WORK/root/scripts/"
cp "$REPO/scripts/lib/secret-values.sh" "$WORK/root/scripts/lib/"
printf 'global:\n  domain: "env.example"\n' > "$WORK/root/clusters/org/instances/env/values.yaml"

cat > "$WORK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# get secret NAME [--ignore-not-found] -o jsonpath={.data.KEY}
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
    RESTIC_PASSWORD=restic ./scripts/seal-secrets.sh ctx org env "$@") > "$WORK/out" 2>&1
}
# The JWT_PRIVATE_KEY sealed in the last secrets.yaml, decoded.
sealed_private_key() {
  awk '/name: env-jwt-signing-secret/ { f = 1 } f && /JWT_PRIVATE_KEY:/ { print $2; exit }' \
    "$WORK/root/clusters/org/instances/env/secrets.yaml" | base64 -d
}

echo "== first sealing: a key pair is generated"
rm -rf "$WORK/cluster"; mkdir -p "$WORK/cluster"
if run; then ok "seal-secrets.sh succeeds"; else fail "seal-secrets.sh failed: $(cat "$WORK/out")"; fi
key1="$(sealed_private_key)"
if printf '%s\n' "$key1" | openssl pkey -noout -text 2>/dev/null | grep -q ED25519; then
  ok "env-jwt-signing-secret holds an Ed25519 private key"
else
  fail "no Ed25519 JWT_PRIVATE_KEY sealed in env-jwt-signing-secret"
fi
pub1="$(printf '%s\n' "$key1" | openssl pkey -pubout 2>/dev/null)"
if grep -qF -- "$(printf '%s\n' "$pub1" | sed -n 2p)" "$WORK/out" && grep -q 'publicKey: |' "$WORK/out"; then
  ok "its public half is printed as a global.jwt.publicKey snippet"
else
  fail "public key snippet missing from the output"
fi
if grep -q 'PRIVATE KEY' "$WORK/out"; then fail "the private key leaks to the output"; else ok "the private key is never printed"; fi
if awk '/^ *name: / { f = ($2 == "env-app-secrets") } f' "$WORK/root/clusters/org/instances/env/secrets.yaml" | grep -q JWT_PRIVATE_KEY; then
  fail "JWT_PRIVATE_KEY also sealed in the app Secret every service reads"
else
  ok "JWT_PRIVATE_KEY is only in the signing Secret"
fi

echo "== re-run and --rotate: the key on the cluster is kept"
mkdir -p "$WORK/cluster/env-jwt-signing-secret"
printf '%s\n' "$key1" > "$WORK/cluster/env-jwt-signing-secret/JWT_PRIVATE_KEY"
for mode in "" --rotate; do
  if run $mode; then ok "seal-secrets.sh ${mode:-(no flag)} succeeds"; else fail "seal-secrets.sh $mode failed: $(cat "$WORK/out")"; fi
  if [ "$(sealed_private_key)" = "$key1" ]; then ok "${mode:-re-run}: same private key sealed again"; else fail "${mode:-re-run}: the signing key was replaced"; fi
done

echo "== the public key already in values.yaml is not asked again"
{ echo "  jwt:"; echo "    publicKey: |"; printf '%s\n' "$pub1" | sed 's/^/      /'; } >> "$WORK/root/clusters/org/instances/env/values.yaml"
run
if grep -q 'already in' "$WORK/out" && ! grep -q 'publicKey: |' "$WORK/out"; then
  ok "reports the public key as already published"
else
  fail "asks again for a public key values.yaml already has"
fi

echo "== a failed read of the cluster stops the script"
before="$(cat "$WORK/root/clusters/org/instances/env/secrets.yaml")"
if KUBECTL_FAIL=1 run; then fail "seal-secrets.sh succeeded while kubectl failed"; else ok "seal-secrets.sh fails"; fi
if [ "$(cat "$WORK/root/clusters/org/instances/env/secrets.yaml")" = "$before" ]; then
  ok "secrets.yaml is left untouched"
else
  fail "secrets.yaml was rewritten after a failed read"
fi

exit "$FAILED"
