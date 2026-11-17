#!/usr/bin/env bash
# MAIR-805: seal-secrets.sh gives each instance one TOTP_ENCRYPTION_KEY (base64
# of 32 bytes) in <env>-app-secrets: generated when the cluster has none, ALWAYS
# kept afterwards (also with --rotate: a new key makes every enrolled second
# factor unreadable), imposed by TOTP_ENCRYPTION_KEY, refused when not 32 bytes.
# kubectl and kubeseal are stubbed like in mair_680_seal_signing_key_test.sh.
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
    RESTIC_PASSWORD=restic ./scripts/seal-secrets.sh ctx org env "$@") > "$WORK/out" 2>&1
}
# TOTP_ENCRYPTION_KEY sealed in the app Secret of the last secrets.yaml, decoded.
sealed_totp() {
  awk '/name: env-app-secrets/ { f = 1 } f && /TOTP_ENCRYPTION_KEY:/ { print $2; exit }' \
    "$WORK/root/clusters/org/instances/env/secrets.yaml" | base64 -d
}
is_32_bytes() { [ "$(printf '%s' "$1" | base64 -d 2>/dev/null | wc -c)" = 32 ]; }

echo "== first sealing: a key is generated"
rm -rf "$WORK/cluster"; mkdir -p "$WORK/cluster"
if run; then ok "seal-secrets.sh succeeds"; else fail "seal-secrets.sh failed: $(cat "$WORK/out")"; fi
key1="$(sealed_totp)"
if is_32_bytes "$key1"; then ok "app Secret holds a base64 32-byte TOTP_ENCRYPTION_KEY"; else fail "no valid TOTP_ENCRYPTION_KEY sealed: '$key1'"; fi
if grep -qF -- "$key1" "$WORK/out"; then fail "the key leaks to the output"; else ok "the key is never printed"; fi

echo "== re-run and --rotate keep the key of the cluster"
mkdir -p "$WORK/cluster/env-app-secrets"
printf '%s' "$key1" > "$WORK/cluster/env-app-secrets/TOTP_ENCRYPTION_KEY"
for mode in "" --rotate; do
  rm -f "$WORK/root/clusters/org/instances/env/secrets.yaml"
  if run $mode; then ok "seal-secrets.sh ${mode:-(no flag)} succeeds"; else fail "${mode:-re-run} failed: $(cat "$WORK/out")"; fi
  if [ "$(sealed_totp)" = "$key1" ]; then ok "${mode:-re-run}: same key sealed again"; else fail "${mode:-re-run}: the key was replaced"; fi
done

echo "== TOTP_ENCRYPTION_KEY imposes a key, a wrong length is refused"
good="$(head -c 32 /dev/zero | base64)"
rm -f "$WORK/root/clusters/org/instances/env/secrets.yaml"
TOTP_ENCRYPTION_KEY="$good" run
if [ "$(sealed_totp)" = "$good" ]; then ok "the imposed key is sealed"; else fail "imposed key not used"; fi
if TOTP_ENCRYPTION_KEY="$(printf short | base64)" run; then fail "a short key was accepted"; else ok "a short key is refused"; fi

exit "$FAILED"
