#!/usr/bin/env bash
# MAIR-444: argocd-image-updater commits staging's image tags straight onto
# the `staging` branch (clusters/<org>/instances/staging/images.yaml). Promote
# used to refuse anything but a fast-forward, so the first such commit would
# have blocked every later promotion to staging. scripts/promote-mode.sh must
# merge main into staging when staging is ahead by those commits only, and
# keep refusing every other divergence.
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/scripts/promote-mode.sh"

REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT
cd "$REPO" || exit 1
git init -q -b main
git config user.email test@example.invalid
git config user.name test
commit() { # commit <file> <message>
  mkdir -p "$(dirname "$1")"; echo "$2" >> "$1"; git add "$1"; git commit -qm "$2"; git rev-parse HEAD
}

FAILED=0
expect() { # expect <stdout|fail> <description> <args...>
  local want=$1 what=$2; shift 2
  local got
  if got=$("$SCRIPT" "$@" 2>/dev/null); then :; else got=fail; fi
  if [ "$got" = "$want" ]; then echo "  OK    $what: $got"; else echo "  FAIL  $what: expected '$want', got '$got'"; FAILED=1; fi
}

M1=$(commit charts/a.yaml "main 1")
M2=$(commit charts/a.yaml "main 2")

# staging = M1, then image-updater commits on it.
git checkout -q -b staging "$M1"
S_IMG=$(commit clusters/mairie360/instances/staging/images.yaml "staging tags")

expect "fast-forward true" "new staging branch"                staging "$M2" ""
expect "fast-forward true" "staging behind main"               staging "$M2" "$M1"
expect "none false"        "commit already in staging"         staging "$M1" "$S_IMG"
expect "merge true"        "staging ahead by image tags only"  staging "$M2" "$S_IMG"
expect "fail"              "prod never merges"                 prod    "$M2" "$S_IMG"

# The same after a first merge: the next promotion merges again.
git merge -q --no-ff --no-edit "$M2"
S_MERGED=$(git rev-parse HEAD)
S_IMG2=$(commit clusters/mairie360/instances/staging/images.yaml "staging tags 2")
git checkout -q main
M3=$(commit charts/a.yaml "main 3")
expect "merge true"        "second promotion after a merge"    staging "$M3" "$S_IMG2"

# Anything else committed on staging only is refused.
git checkout -q -b drift "$S_IMG2"
S_DRIFT=$(commit clusters/mairie360/instances/staging/values.yaml "hotfix on staging")
expect "fail"              "staging ahead by another file"     staging "$M3" "$S_DRIFT"

# A change made then reverted on staging is still a staging-only change.
git checkout -q -b reverted "$S_IMG2"
commit clusters/mairie360/instances/staging/values.yaml "edit on staging" >/dev/null
git revert --no-edit HEAD >/dev/null
S_REVERTED=$(git rev-parse HEAD)
expect "fail"              "staging edit reverted later"       staging "$M3" "$S_REVERTED"

# main must never edit the staging images.yaml.
git checkout -q main
M4=$(commit clusters/mairie360/instances/staging/images.yaml "edited on main")
expect "fail"              "main edits staging images.yaml"    staging "$M4" "$S_IMG2"

# Rollbacks.
expect "rollback true"     "rollback to an older staging"      staging "$S_IMG" "$S_MERGED" rollback
expect "fail"              "rollback outside the history"      staging "$M4" "$S_IMG2" rollback

exit "$FAILED"
