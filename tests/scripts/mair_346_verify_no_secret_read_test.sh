#!/usr/bin/env bash
# MAIR-346: the Promote workflow runs scripts/verify.sh on the Argo CD
# machine's runner with a staging ServiceAccount that may not read Secrets nor
# exec into pods (RBAC list at the top of the script). With a fake kubectl
# that denies Secrets, the script must:
#   - never call `kubectl get secret` nor `kubectl exec`;
#   - say it skipped the plaintext checks instead of failing them;
#   - only create probe pods named verify-probe-* (the shape the runner's
#     admission policy admits).
# With a context that may read Secrets, it must run the plaintext checks.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Fake kubectl: logs every call, answers `auth can-i get secrets` from
# $CAN_READ, reports empty objects for everything else.
cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$KUBECTL_LOG"
case "$*" in
  *"auth can-i get secrets"*) [ "$CAN_READ" = yes ] && { echo yes; exit 0; }; echo no; exit 1 ;;
esac
exit 1
SH
chmod +x "$TMP/bin/kubectl"

FAILED=0
check() { if eval "$2"; then echo "  OK    $1"; else echo "  FAIL  $1"; FAILED=1; fi; }

run() { # run <yes|no>: verify.sh against the fake, without domain
  : > "$TMP/log.$1"
  PATH="$TMP/bin:$PATH" KUBECTL_LOG="$TMP/log.$1" CAN_READ=$1 \
    "$ROOT/scripts/verify.sh" fake staging > "$TMP/out.$1" 2>&1 || true
}

run no
check "no Secret read without the permission" "! grep -qE '(^| )get secrets? ' '$TMP/log.no'"
check "no pods/exec" "! grep -qE '(^| )exec ' '$TMP/log.no'"
check "plaintext checks reported as skipped" "grep -q 'plaintext checks\|ADMIN_PASSWORD format and URL-safe passwords skipped' '$TMP/out.no'"
check "every probe pod is named verify-probe-*" \
  "! grep -E '(^| )run ' '$TMP/log.no' | grep -vqE '(^| )run verify-probe-'"
check "the probes ran (the fake saw them)" "grep -qE '(^| )run verify-probe-' '$TMP/log.no'"

run yes
check "Secrets read when the context may" "grep -qE '(^| )get secret ' '$TMP/log.yes'"

exit "$FAILED"
