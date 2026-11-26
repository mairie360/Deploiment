#!/usr/bin/env bash
# MAIR-1193 (control D-12): scripts/check-signed-images.sh must pass when every running mairie360
# image is a cosign-signed digest, and fail when one is unsigned. A fake cosign replays the verdict;
# no cluster and no real registry are needed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/check-signed-images.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
FAILED=0
check() { if [ "$1" = "$2" ]; then echo "  OK   $3"; else echo "  FAIL $3 (got '$2', want '$1')"; FAILED=1; fi; }

# Fake cosign: verifies any ref except those holding the word "tampered".
cat > "$TMP/bin/cosign" <<'EOF'
#!/usr/bin/env bash
# cosign verify <ref> --flags...: the ref is the first argument after the subcommand.
case "$2" in *tampered*) exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$TMP/bin/cosign"
export PATH="$TMP/bin:$PATH"

SIGNED='ghcr.io/mairie360/core-api@sha256:1111111111111111111111111111111111111111111111111111111111111111'
SIGNED2='docker-pullable://ghcr.io/mairie360/user-bff@sha256:2222222222222222222222222222222222222222222222222222222222222222'
UNSIGNED='ghcr.io/mairie360/tampered-api@sha256:3333333333333333333333333333333333333333333333333333333333333333'
PUBLIC='docker.io/library/redis:7@sha256:4444444444444444444444444444444444444444444444444444444444444444'
NOTAG='ghcr.io/mairie360/project-api'   # no digest

# 1. Only signed mairie360 digests (+ a public image, skipped) → exit 0.
printf '%s\n%s\n%s\n' "$SIGNED" "$SIGNED2" "$PUBLIC" | "$SCRIPT" >"$TMP/out1" 2>&1; code=$?
check 0 "$code" "signed images pass"
if grep -q "SKIP  not a mairie360 image: $PUBLIC" "$TMP/out1"; then echo "  OK   public image skipped"; else echo "  FAIL public image not skipped"; FAILED=1; fi

# 2. One unsigned mairie360 digest → exit 1, named.
printf '%s\n%s\n' "$SIGNED" "$UNSIGNED" | "$SCRIPT" >"$TMP/out2" 2>&1; code=$?
check 1 "$code" "an unsigned mairie360 image fails"
if grep -q "FAIL  unsigned or invalid signature: $UNSIGNED" "$TMP/out2"; then echo "  OK   unsigned image named"; else echo "  FAIL unsigned image not named"; FAILED=1; fi

# 3. A mairie360 image without a digest cannot be verified → listed, and (alone) exits 0 (skipped).
printf '%s\n' "$NOTAG" | "$SCRIPT" >"$TMP/out3" 2>&1; code=$?
check 0 "$code" "a digest-less image is skipped, not failed"
if grep -q "SKIP  no digest, cannot verify: $NOTAG" "$TMP/out3"; then echo "  OK   digest-less image reported"; else echo "  FAIL digest-less image not reported"; FAILED=1; fi

# 4. cosign absent → skipped, exit 0.
PATH="/usr/bin:/bin" printf '%s\n' "$SIGNED" > "$TMP/in4"
env PATH="/usr/bin:/bin" bash "$SCRIPT" < "$TMP/in4" >"$TMP/out4" 2>&1; code=$?
check 0 "$code" "cosign absent is a skip"
if grep -q "cosign not found" "$TMP/out4"; then echo "  OK   cosign-absent notice"; else echo "  FAIL no cosign-absent notice"; FAILED=1; fi

if [ $FAILED -eq 0 ]; then echo "PASS"; else echo "FAIL"; exit 1; fi
