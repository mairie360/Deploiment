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

# --- Review follow-ups (merge commits, large path lists) -----------------------------------------
IMG=clusters/mairie360/instances/staging/images.yaml
git checkout -q main
push main main:staging main:prod

# A promotion merge (main into staging, after an image-updater commit) is not a divergence.
git checkout -q -b promo staging 2>/dev/null || git checkout -q -B promo main
git reset -q --hard main
commit "$IMG" "chore: image-updater staging tags again"
git checkout -q main
commit charts/a.yaml "main 5"
git checkout -q promo
git merge -q --no-ff --no-edit main
push main promo:staging main:prod
passes "an ordinary promotion merge is allowed"

# A forbidden edit hidden in a merge commit must be caught (git log --no-merges skipped it).
git checkout -q -B evil main
commit "$IMG" "chore: image-updater tags before the evil merge"
git checkout -q main
commit charts/a.yaml "main 6"
git checkout -q evil
git merge -q --no-ff --no-commit main
echo "hand edit" >>clusters/mairie360/instances/staging/values.yaml
git add clusters/mairie360/instances/staging/values.yaml
git commit -qm "Merge main into staging (with a hand edit)"
push evil:staging
fails "a values.yaml edit introduced by a staging-only merge commit"
says "Merge main into staging (with a hand edit)" "lists the merge commit"
# main moves on after the evil merge: the Promote must refuse to merge it into that staging.
git checkout -q main
commit charts/a.yaml "main 6b"
out=$("$MODE" staging "$(git rev-parse main)" "$(git rev-parse evil)" 2>&1 >/dev/null); code=$?
ok "$([ "$code" != 0 ] && grep -q "values.yaml" <<<"$out" && echo 0 || echo 1)" "promote-mode refuses the hand edit hidden in a merge commit"

# A commit with many non-image paths: grep must read the whole list (no early exit under pipefail).
git checkout -q -B many main
for i in $(seq 1 400); do mkdir -p charts/many; echo "$i" >"charts/many/file-$i.yaml"; done
git add charts/many && git commit -qm "fix: hundreds of files on staging only"
push many:staging main:prod
fails "a staging-only commit changing hundreds of non-image paths"

# prod holding only a merge commit of its own is listed (promote-mode and the check).
git checkout -q -B prod-merge main
git checkout -q -b side main
commit clusters/_base/prod.yaml "side change"
git checkout -q prod-merge
git merge -q --no-ff -m "Merge side straight on prod" side
push main:staging prod-merge:prod
fails "prod holding a merge commit of its own"
says "Merge side straight on prod" "the check lists the merge commit"
git checkout -q main
commit charts/a.yaml "main 7"
out=$("$MODE" prod "$(git rev-parse main)" "$(git rev-parse prod-merge)" 2>&1 >/dev/null)
ok "$(grep -qF "Merge side straight on prod" <<<"$out" && echo 0 || echo 1)" "promote-mode lists the target-only merge commit"

out=$("$CHECK" "$TMP/missing.git" 2>&1); code=$?
ok "$([ "$code" != 0 ] && echo 0 || echo 1)" "unreachable remote: fails"

exit "$failed"
