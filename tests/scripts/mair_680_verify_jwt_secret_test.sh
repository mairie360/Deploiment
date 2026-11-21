#!/usr/bin/env bash
# MAIR-680: scripts/verify.sh step 5b reports a workload that still gets the
# removed JWT_SECRET, and a failed read of the workloads is a failure, never an
# "OK" (with pipefail, a failing kubectl in front of grep used to take the OK
# branch). A fake kubectl answers the deployments/statefulsets read from
# $WORKLOADS: fail, leak (a JWT_SECRET env entry) or clean.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"get deploy,statefulset -o yaml")
    case "$WORKLOADS" in
      fail) echo "forbidden" >&2; exit 1 ;;
      leak) printf 'kind: Deployment\nspec:\n  env:\n  - name: JWT_SECRET\n'; exit 0 ;;
      clean) printf 'kind: Deployment\nspec:\n  env:\n  - name: JWT_PUBLIC_KEY\n'; exit 0 ;;
    esac ;;
esac
exit 1
SH
chmod +x "$TMP/bin/kubectl"

FAILED=0
check() { if eval "$2"; then echo "  OK    $1"; else echo "  FAIL  $1"; FAILED=1; fi; }

run() { # run <fail|leak|clean>: verify.sh against the fake, without domain
  PATH="$TMP/bin:$PATH" WORKLOADS=$1 "$ROOT/scripts/verify.sh" fake dev > "$TMP/out.$1" 2>&1 || true
}

run fail
check "a failed workload read is reported as a failure" \
  "grep -q 'FAIL.*cannot read the deployments and statefulsets' '$TMP/out.fail'"
check "a failed workload read is never reported as OK" \
  "! grep -q 'OK.*no workload gets JWT_SECRET' '$TMP/out.fail'"

run leak
check "a workload with JWT_SECRET fails" "grep -q 'FAIL.*still gets JWT_SECRET' '$TMP/out.leak'"

run clean
check "no JWT_SECRET is OK" "grep -q 'OK.*no workload gets JWT_SECRET' '$TMP/out.clean'"

exit "$FAILED"
