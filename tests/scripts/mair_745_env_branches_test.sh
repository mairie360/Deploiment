#!/usr/bin/env bash
# MAIR-745: the staging and prod branches were deleted on 2026-10-23 and
# nothing reported it. scripts/check-env-branches.sh must pass while both
# exist and fail, naming the branch, as soon as one is gone.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/check-env-branches.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failed=0

check() {
  if [ "$1" = 0 ]; then echo "  OK    $2"; else echo "  FAIL  $2"; failed=1; fi
}

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/work"
git -C "$TMP/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$TMP/work" push -q "$TMP/remote.git" main main:staging main:prod

out=$("$CHECK" "$TMP/remote.git" 2>&1); code=$?
check "$([ "$code" = 0 ] && echo 0 || echo 1)" "both branches present: exit 0"

git -C "$TMP/work" push -q "$TMP/remote.git" --delete staging
out=$("$CHECK" "$TMP/remote.git" 2>&1); code=$?
check "$([ "$code" != 0 ] && echo 0 || echo 1)" "staging deleted: fails"
check "$(grep -q "Branch 'staging' is missing" <<<"$out" && echo 0 || echo 1)" "staging deleted: names staging"
check "$(grep -q "OK    prod" <<<"$out" && echo 0 || echo 1)" "staging deleted: prod still reported"

git -C "$TMP/work" push -q "$TMP/remote.git" main:staging
git -C "$TMP/work" push -q "$TMP/remote.git" --delete prod
out=$("$CHECK" "$TMP/remote.git" 2>&1); code=$?
check "$([ "$code" != 0 ] && echo 0 || echo 1)" "prod deleted: fails"
check "$(grep -q "Branch 'prod' is missing" <<<"$out" && echo 0 || echo 1)" "prod deleted: names prod"

out=$("$CHECK" "$TMP/missing.git" 2>&1); code=$?
check "$([ "$code" != 0 ] && echo 0 || echo 1)" "unreachable remote: fails"

exit "$failed"
