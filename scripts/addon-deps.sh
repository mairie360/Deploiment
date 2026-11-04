#!/usr/bin/env bash
# =============================================================================
# Download the upstream chart of bootstrap wrapper charts (MAIR-346).
#
#   ./scripts/addon-deps.sh bootstrap/addons/<addon> [...]
#
# `helm dependency build` resolves a dependency's `repository:` URL only
# through a repository added with `helm repo add` (Argo CD does that by
# itself). This adds each wrapper's repositories to a throwaway Helm
# repository config, so the caller's own config is left untouched, then
# builds the dependencies against the committed Chart.lock. Used by CI
# (cicd.yaml) and tests/e2e/run.sh. Needs helm and python3 with PyYAML.
# =============================================================================
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 <wrapper chart dir>..." >&2; exit 2; }
HELM_HOME=$(mktemp -d)
trap 'rm -rf "$HELM_HOME"' EXIT
export HELM_REPOSITORY_CONFIG="$HELM_HOME/repositories.yaml"
export HELM_REPOSITORY_CACHE="$HELM_HOME/cache"

for chart in "$@"; do
  python3 -c '
import sys, yaml
for d in yaml.safe_load(open(sys.argv[1]))["dependencies"]:
    print(d["name"], d["repository"])' "$chart/Chart.yaml" \
  | while read -r name url; do
      helm repo add --force-update "$name" "$url" >/dev/null
    done
  helm dependency build "$chart" >/dev/null
done
