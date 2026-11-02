#!/usr/bin/env bash
# =============================================================================
# How the Promote workflow moves <target> to <sha> (MAIR-444).
#
#   ./scripts/promote-mode.sh <staging|prod> <sha> <current|""> [rollback]
#
# <current> is the target branch's head ("" when the branch does not exist
# yet), `rollback` asks to move it back to a commit already in its history.
# Prints "<mode> <changed>" on stdout:
#
#   fast-forward true   the branch moves to <sha> (or is created there)
#   merge true          staging only: <sha> is merged into staging, keeping
#                       the image tags argocd-image-updater committed there
#   rollback true       the branch is forced back to <sha>
#   none false          <sha> is already in the branch, nothing to do
#
# and fails (::error:: on stderr) on any other path. Staging may be ahead of
# main by argocd-image-updater commits only, i.e. commits that edit nothing
# but clusters/<org>/instances/staging/images.yaml, and main must never edit
# that file, so the merge cannot conflict. Prod only fast-forwards.
# Runs in a clone with both commits fetched.
# =============================================================================
set -euo pipefail

TARGET=$1 SHA=$2 CURRENT=${3:-} ROLLBACK=${4:-}
IMAGES_RE='^clusters/[^/]+/instances/staging/images\.yaml$'

err() { echo "::error::$*" >&2; exit 1; }

if [ "$ROLLBACK" = "rollback" ]; then
  [ -n "$CURRENT" ] || err "'$TARGET' does not exist, nothing to roll back."
  git merge-base --is-ancestor "$SHA" "$CURRENT" \
    || err "Rollback needs a commit that is already in '$TARGET' history."
  if [ "$SHA" = "$CURRENT" ]; then echo "none false"; else echo "rollback true"; fi
  exit 0
fi

if [ -z "$CURRENT" ]; then echo "fast-forward true"; exit 0; fi
# Already in the target (staging merged it, or it is its head).
if git merge-base --is-ancestor "$SHA" "$CURRENT"; then echo "none false"; exit 0; fi
if git merge-base --is-ancestor "$CURRENT" "$SHA"; then echo "fast-forward true"; exit 0; fi

BASE=$(git merge-base "$SHA" "$CURRENT")
# Every file touched by a commit that is only on the target, not just the
# final diff: a change made then reverted on staging is refused too. Merge
# commits (former promotions) only bring main in, skip them.
touched() { git log --no-merges --format= --name-only "$1" | sed '/^$/d' | sort -u; }
OTHER=$(touched "$BASE..$CURRENT" | grep -vE "$IMAGES_RE" || true)
if [ "$TARGET" != "staging" ] || [ -n "$OTHER" ]; then
  [ -z "$OTHER" ] || echo "::error::Changed only on $TARGET: $(echo $OTHER)" >&2
  err "'$TARGET' ($CURRENT) is not an ancestor of $SHA: not a fast-forward."
fi
if touched "$BASE..$SHA" | grep -qE "$IMAGES_RE"; then
  err "$SHA edits a staging images.yaml on main: only argocd-image-updater writes it, on staging."
fi
echo "merge true"
