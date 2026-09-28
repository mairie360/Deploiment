#!/usr/bin/env bash
# =============================================================================
# Check that every instance references images that actually exist (MAIR-172).
#
#   ./scripts/check-image-tags.sh [--offline] [instance-dir ...]
#
# Instance dirs are relative to the repo root (or absolute).
#
# Renders each instance (default: every clusters/*/instances/*) and checks
# every image of the result:
#
#   1. Tag policy, for ghcr.io/mairie360/* images only. The starting tag must
#      belong to the family argocd-image-updater tracks for that environment
#      (ansible, roles/k8s_argocd/defaults/main.yml `image_updater_policies`),
#      so an instance starts before the image-updater's first pass and the
#      image-updater can then move it forward:
#        dev      -> dev-<git sha>
#        staging  -> staging-<git sha>
#        other    -> published semver (X.Y.Z), e.g. prod and client instances
#      Mobile tags (`latest`, `dev-latest`, `dev`, ...) are rejected: they are
#      either no longer pushed (`*-latest` since the CICD `docker-release`
#      action) or make the running image depend on when the node pulled it.
#   2. Existence, for every image (ours and third-party): the manifest must be
#      readable from its registry. Skipped with --offline.
#
# Registry access is anonymous (the mairie360 images are public). Export
# GHCR_USER / GHCR_TOKEN to authenticate against ghcr.io instead.
# Needs helm (with `helm dependency build` done) and, unless --offline, skopeo.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
CHART=./charts/mairie360-stack
OFFLINE=0
if [ "${1:-}" = "--offline" ]; then OFFLINE=1; shift; fi
if [ $# -gt 0 ]; then INSTANCES=("$@"); else INSTANCES=(clusters/*/instances/*); fi

SHA_RE='[0-9a-f]{7,40}'
SEMVER_RE='^v?[0-9]+\.[0-9]+\.[0-9]+$'
FAILED=0
ALL_IMAGES=$(mktemp)
trap 'rm -f "$ALL_IMAGES"' EXIT

ko() { printf '  \033[31mKO\033[0m %s\n' "$1"; FAILED=1; }

# Prints the image references of a rendered instance, one per line.
rendered_images() {
  helm template r "$CHART" -f "$1/values.yaml" \
    | sed -nE 's/^[[:space:]]*(- )?image:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\2/p' \
    | sort -u
}

for dir in "${INSTANCES[@]}"; do
  env=$(basename "$dir")
  case "$env" in
    dev|staging) policy="^${env}-${SHA_RE}\$"; expected="${env}-<git sha>" ;;
    *)           policy="$SEMVER_RE";          expected="semver X.Y.Z" ;;
  esac
  echo "[$dir] expecting $expected on ghcr.io/mairie360/*"

  if ! images=$(rendered_images "$dir") || [ -z "$images" ]; then
    ko "$dir: render failed or produced no image"
    continue
  fi
  echo "$images" >> "$ALL_IMAGES"

  while read -r ref; do
    case "$ref" in ghcr.io/mairie360/*) ;; *) continue ;; esac
    tag=${ref##*:}
    if [ "$tag" = "$ref" ] || [[ "$ref" == *@* ]]; then
      ko "$ref: no tag"
    elif ! [[ "$tag" =~ $policy ]]; then
      ko "$ref: tag '$tag' is not $expected"
    fi
  done <<< "$images"
done

if [ "$OFFLINE" -eq 0 ]; then
  echo "[registry] checking that every image exists"
  CREDS=()
  [ -n "${GHCR_USER:-}" ] && [ -n "${GHCR_TOKEN:-}" ] && CREDS=(--creds "$GHCR_USER:$GHCR_TOKEN")
  export CREDS_ARG="${CREDS[*]:-}"
  # One lookup per unique image, 8 at a time, one retry for registry hiccups.
  # shellcheck disable=SC2016 # $1 / $CREDS_ARG are expanded by the inner sh
  MISSING=$(sort -u "$ALL_IMAGES" | xargs -P 8 -I{} sh -c '
    ref="$1"
    case "$ref" in ghcr.io/*) creds="$CREDS_ARG" ;; *) creds="" ;; esac
    for _ in 1 2; do
      skopeo inspect --raw $creds "docker://$ref" >/dev/null 2>&1 && exit 0
      sleep 2
    done
    echo "$ref"
  ' _ {})
  for ref in $MISSING; do ko "$ref: not found in its registry"; done
  [ -z "$MISSING" ] && echo "  all $(sort -u "$ALL_IMAGES" | wc -l) images found"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "Image tag check failed." >&2
  exit 1
fi
echo "Image tag check passed."
