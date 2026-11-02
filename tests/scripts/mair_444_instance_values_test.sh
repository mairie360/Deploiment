#!/usr/bin/env bash
# MAIR-444: the staging image tags committed by argocd-image-updater live in
# <instance>/images.yaml. Every script that renders an instance must read it
# right after values.yaml (it overrides the seed tags there) and before the
# secrets, and only when it exists.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILED=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  OK    $1"; else printf '  FAIL  %s\n    expected: %s\n    got:      %s\n' "$1" "$2" "$3"; FAILED=1; fi
}
names() { "$ROOT/scripts/instance-values.sh" "$@" | sed "s#^$ROOT/##" | tr '\n' ' '; }

check "staging reads images.yaml after values.yaml" \
  "clusters/mairie360/instances/staging/values.yaml clusters/mairie360/instances/staging/images.yaml " \
  "$(names clusters/mairie360/instances/staging)"
check "staging reads images.yaml before the secrets" \
  "clusters/mairie360/instances/staging/values.yaml clusters/mairie360/instances/staging/images.yaml clusters/mairie360/instances/staging/secrets.yaml " \
  "$(names clusters/mairie360/instances/staging --secrets)"
check "dev has no images.yaml" \
  "clusters/mairie360/instances/dev/values.yaml " \
  "$(names clusters/mairie360/instances/dev)"

exit "$FAILED"
