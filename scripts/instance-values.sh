#!/usr/bin/env bash
# =============================================================================
# Print the values files of an instance, in the order the instances
# ApplicationSet (ansible, roles/k8s_argocd) passes them to Helm (MAIR-414):
#
#   ./scripts/instance-values.sh <instance-dir> [--secrets]
#
#   clusters/_base/<env>.yaml   when it exists (shared by every <env> instance)
#   <instance-dir>/values.yaml
#   <instance-dir>/secrets.yaml with --secrets, when it exists
#
# One path per line; build the -f arguments with:
#   mapfile -t files < <(./scripts/instance-values.sh "$dir")
#   args=(); for f in "${files[@]}"; do args+=(-f "$f"); done
# =============================================================================
set -euo pipefail
dir="${1:?usage: $0 <instance-dir> [--secrets]}"
dir="${dir%/}"
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$dir" in /*) ;; *) dir="$root/$dir" ;; esac
base="$root/clusters/_base/$(basename "$dir").yaml"
[ ! -f "$base" ] || echo "$base"
echo "$dir/values.yaml"
if [ "${2:-}" = "--secrets" ] && [ -f "$dir/secrets.yaml" ]; then
  echo "$dir/secrets.yaml"
fi
