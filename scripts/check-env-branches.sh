#!/usr/bin/env bash
# MAIR-745: staging and prod each follow their own branch of this repo
# (ADR 0002, ansible `deploiment_env_revisions`). When one of those branches
# is missing, the Application of that environment cannot resolve its
# targetRevision and Promote refuses every promotion, while nothing in a PR
# shows it: on 2026-10-23 both branches were deleted and it went unnoticed for
# a week. This check fails as soon as one of them is gone.
#
#   scripts/check-env-branches.sh [remote]   (default: origin; a URL works too)
#
# Run by .github/workflows/environment-branches.yaml on every branch deletion,
# every day and on demand. It reads the remote with `git ls-remote`, so it
# needs no fetch.
set -euo pipefail

REMOTE=${1:-origin}
BRANCHES=(staging prod)

heads=$(git ls-remote --heads "$REMOTE") || {
  echo "::error::Cannot list the branches of '$REMOTE'."
  exit 1
}

missing=0
for branch in "${BRANCHES[@]}"; do
  sha=$(awk -v ref="refs/heads/$branch" '$2 == ref { print substr($1, 1, 7) }' <<<"$heads")
  if [ -n "$sha" ]; then
    echo "OK    $branch at $sha"
  else
    echo "::error::Branch '$branch' is missing: the $branch Application has no revision to follow and Promote refuses every promotion. Recreate it at the commit Argo CD last deployed on $branch (docs/adr/0002-environment-promotion.md, MAIR-745)."
    missing=1
  fi
done
exit "$missing"
