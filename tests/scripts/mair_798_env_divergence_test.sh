#!/usr/bin/env bash
# MAIR-798: a fix pushed straight onto `prod` (2026-11-06, MAIR-794) made the
# next Promote fail with a bare "not a fast-forward" and nothing reported the
# divergence before. scripts/check-env-divergence.sh must pass on the normal
# states (behind, equal, staging ahead by image-updater commits only) and fail
# on a commit made on prod or staging only, and scripts/promote-mode.sh must
# then name the commits and say how to bring them back to main.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/check-env-divergence.sh"
MODE="$ROOT/scripts/promote-mode.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failed=0

ok() { if [ "$1" = 0 ]; then echo "  OK    $2"; else echo "  FAIL  $2"; failed=1; fi; }
passes() { "$CHECK" "$TMP/remote.git" >"$TMP/out" 2>&1; ok "$([ $? = 0 ] && echo 0 || echo 1)" "$1"; }
fails() { "$CHECK" "$TMP/remote.git" >"$TMP/out" 2>&1; ok "$([ $? != 0 ] && echo 0 || echo 1)" "$1"; }
says() { ok "$(grep -qF -- "$1" "$TMP/out" && echo 0 || echo 1)" "$2"; }

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/work"
cd "$TMP/work" || exit 1
git config user.email test@example.invalid
git config user.name test
commit() { mkdir -p "$(dirname "$1")"; echo "$2" >>"$1"; git add "$1"; git commit -qm "$2"; }
push() { git push -q --force "$TMP/remote.git" "$@"; }

commit charts/a.yaml "main 1"
push main main:staging main:prod
passes "all three branches on the same commit"

commit charts/a.yaml "main 2"
push main main:staging
passes "prod behind staging, staging equal to main"

commit charts/a.yaml "main 3"
push main
passes "staging behind main"

git checkout -q -b staging-work "$(git rev-parse main~1)"
commit clusters/mairie360/instances/staging/images.yaml "chore: image-updater staging tags"
push staging-work:staging
passes "staging ahead of main by image-updater commits only"

# The incident: a fix committed on prod only.
git checkout -q -b prod-work "$(git rev-parse main~2)"
commit clusters/_base/prod.yaml "fix: hotfix straight on prod"
push prod-work:prod
fails "a commit made on prod only"
says "'prod' has diverged from 'staging'" "names the diverged branch"
says "hotfix straight on prod" "lists the commit made on prod only"
says "merges origin/prod into main with a merge commit" "says how to bring it back"
says "OK    staging is main plus" "still reports staging"

# Recovery: prod merged back into main, then promoted (MAIR-1003).
git checkout -q main
git merge -q --no-ff --no-edit prod-work
push main main:staging main:prod
passes "prod merged back into main and promoted"

# A change on staging other than its images.yaml.
git checkout -q -b drift main
commit clusters/mairie360/instances/staging/values.yaml "fix: edit staging values by hand"
push drift:staging
fails "a commit made on staging only, outside images.yaml"
says "'staging' has diverged from 'main'" "names staging"
says "edit staging values by hand" "lists the staging-only commit"

# prod only AHEAD of staging (promote-mode answers "none" for that one).
git checkout -q -b ahead main
commit clusters/_base/prod.yaml "fix: another hotfix on prod"
push main:staging ahead:prod
fails "prod ahead of staging by a commit of its own"
says "another hotfix on prod" "lists it"

# The Promote itself prints the same guidance (promote-mode.sh).
git checkout -q main
commit charts/a.yaml "main 4"
out=$("$MODE" prod "$(git rev-parse main)" "$(git rev-parse ahead)" 2>&1 >/dev/null)
ok "$(grep -qF "then promote main to staging, then staging to prod" <<<"$out" && echo 0 || echo 1)" \
  "promote-mode explains the way back for prod"

out=$("$CHECK" "$TMP/missing.git" 2>&1); code=$?
ok "$([ "$code" != 0 ] && echo 0 || echo 1)" "unreachable remote: fails"

exit "$failed"
