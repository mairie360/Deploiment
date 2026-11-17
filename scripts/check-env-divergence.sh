#!/usr/bin/env bash
# MAIR-798: on 2026-11-06 a fix was pushed straight onto `prod` (MAIR-794).
# Nothing reported it, and the next Promote to prod failed as "not a
# fast-forward". This check reports such a divergence as soon as it happens:
#
#   - `staging` may only be ahead of `main` by argocd-image-updater commits
#     (MAIR-444), which the next Promote merges;
#   - `prod` must always be an ancestor of `staging`.
#
# Same rules as scripts/promote-mode.sh, checked even when the branch is only
# AHEAD (promote-mode answers "nothing to do" then, and the divergence would
# only surface once the source moves). On failure it lists the commits in the
# way and how to bring them back to main.
#
#   scripts/check-env-divergence.sh [remote]   (default: origin; a URL works too)
#
# Run by .github/workflows/environment-branches.yaml on every push to staging
# or prod, every day and on demand. It fetches the three branches itself into
# refs/env-check/, so it needs a full clone (fetch-depth: 0), not a fetch.
set -euo pipefail

REMOTE=${1:-origin}

git fetch --quiet --no-tags "$REMOTE" \
  "+refs/heads/main:refs/env-check/main" \
  "+refs/heads/staging:refs/env-check/staging" \
  "+refs/heads/prod:refs/env-check/prod" || {
  echo "::error::Cannot fetch main, staging and prod from '$REMOTE' (scripts/check-env-branches.sh tells which one is missing)."
  exit 1
}

IMAGES_RE='^clusters/[^/]+/instances/staging/images\.yaml$'
failed=0

# report <target> <source> <commits>: the divergence and the way back.
report() {
  local target=$1 source=$2 commits=$3
  echo "Commits on '$target' that never came from '$source':"
  sed 's/^/  /' <<<"$commits" | head -n 20
  echo "::error::'$target' has diverged from '$source': the next Promote to $target will fail. Bring these commits back: open a pull request that merges origin/$target into main with a merge commit (not a squash), then promote main to staging$([ "$target" = prod ] && echo ", then staging to prod"). Never force-push '$target' (MAIR-798)."
  failed=1
}

# staging: ahead of main by argocd-image-updater commits only (MAIR-444).
# A promotion merge (main into staging) only brings main in: `--cc` lists the
# files a merge changes against ALL its parents, so a clean merge shows none and
# an edit hidden in a merge commit is still caught. grep reads the whole list
# (no -q), or an early exit would make `pipefail` hide a forbidden change.
others=""
while read -r sha subject; do
  [ -n "$sha" ] || continue
  if git diff-tree --cc --no-commit-id --name-only -r "$sha" | grep -vE "$IMAGES_RE" >/dev/null; then
    others+="${sha::7} $subject"$'\n'
  fi
done < <(git log --format='%H %s' refs/env-check/main..refs/env-check/staging)
if [ -n "$others" ]; then
  report staging main "${others%$'\n'}"
else
  echo "OK    staging is main plus argocd-image-updater commits at most"
fi

# prod: always an ancestor of staging (Prod only fast-forwards).
if git merge-base --is-ancestor refs/env-check/prod refs/env-check/staging; then
  echo "OK    prod is an ancestor of staging"
else
  report prod staging "$(git log --format='%h %s' refs/env-check/staging..refs/env-check/prod)"
fi
exit "$failed"
