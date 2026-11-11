#!/usr/bin/env bash
# MAIR-617: the first admin password lives in the team vault (Scaleway Secret
# Manager, written by role k8s_instance_secrets of mairie360/ansible), never in
# a default file on the workstation. Run by hand without ADMIN_PASSWORD,
# seal-secrets.sh used to write a generated plaintext to
# ~/.mairie360/admin-<org>-<env>.txt; it now stops before sealing anything
# unless ADMIN_PASSWORD_FILE names a file explicitly. Keeping the hash already
# sealed on the instance still needs nothing.
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

HASH='$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA'
SECRETS="$WORK/root/clusters/org/instances/env/secrets.yaml"
# Run seal-secrets.sh by hand: no ADMIN_PASSWORD, HOME in the work dir.
# Extra environment assignments come first ("VAR=value ... run").
run() {
  (cd "$WORK/root" && env HOME="$WORK/home" PATH="$WORK/bin:$PATH" FAKE_CLUSTER="$WORK/cluster" \
    ADMIN_EMAIL=admin@example.org RESTIC_PASSWORD=restic "$@" ./scripts/seal-secrets.sh ctx org env) > "$WORK/out" 2>&1
}
fresh() {
  rm -rf "$WORK/cluster" "$WORK/home" "$SECRETS" "$WORK/admin.txt"
  mkdir -p "$WORK/cluster" "$WORK/home"
}
no_local_file() {
  if [ -e "$WORK/home/.mairie360" ]; then fail "$1: wrote $(find "$WORK/home/.mairie360" -type f)"; else ok "$1: nothing under ~/.mairie360"; fi
}

echo "== new instance, no ADMIN_PASSWORD, no ADMIN_PASSWORD_FILE: stops"
fresh
if run; then fail "seal-secrets.sh generated an admin password kept nowhere"; else ok "seal-secrets.sh stops"; fi
if grep -q "playbooks/secrets.yml" "$WORK/out"; then ok "the error points to playbooks/secrets.yml"; else fail "no hint in: $(cat "$WORK/out")"; fi
no_local_file "new instance"
if [ -e "$SECRETS" ]; then fail "secrets.yaml written before stopping"; else ok "nothing sealed"; fi

echo "== plaintext sealed before MAIR-414, no ADMIN_PASSWORD_FILE: stops"
fresh
mkdir -p "$WORK/cluster/env-database-secret"
printf 'old-plaintext' > "$WORK/cluster/env-database-secret/ADMIN_PASSWORD"
if run; then fail "seal-secrets.sh hashed a plaintext it keeps nowhere"; else ok "seal-secrets.sh stops"; fi
no_local_file "pre-MAIR-414 plaintext"

echo "== hash already sealed on the instance: kept, no file"
fresh
mkdir -p "$WORK/cluster/env-database-secret"
printf '%s' "$HASH" > "$WORK/cluster/env-database-secret/ADMIN_PASSWORD"
if run; then ok "seal-secrets.sh succeeds"; else fail "seal-secrets.sh failed: $(cat "$WORK/out")"; fi
if grep -q "ADMIN_PASSWORD   : kept from cluster" "$WORK/out"; then ok "the sealed hash is kept"; else fail "hash not kept: $(cat "$WORK/out")"; fi
no_local_file "sealed hash"

echo "== ADMIN_PASSWORD passed (the ansible role): no file"
fresh
if run ADMIN_PASSWORD="$HASH"; then ok "seal-secrets.sh succeeds"; else fail "seal-secrets.sh failed: $(cat "$WORK/out")"; fi
no_local_file "ADMIN_PASSWORD passed"

echo "== explicit ADMIN_PASSWORD_FILE still works"
if openssl list -kdf-algorithms 2>/dev/null | grep -qi argon2id || command -v argon2 >/dev/null; then
  fresh
  if run ADMIN_PASSWORD_FILE="$WORK/admin.txt"; then ok "seal-secrets.sh succeeds"; else fail "seal-secrets.sh failed: $(cat "$WORK/out")"; fi
  if [ -s "$WORK/admin.txt" ] && [ "$(stat -c %a "$WORK/admin.txt")" = 600 ]; then ok "plaintext written to the given file, mode 600"; else fail "no 600 file at ADMIN_PASSWORD_FILE"; fi
  no_local_file "explicit file"
else
  echo "  SKIP  no argon2id hasher (OpenSSL >= 3.2 or argon2 CLI) on this machine"
fi

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
