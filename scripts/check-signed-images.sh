#!/usr/bin/env bash
# Runtime D-12 check: every mairie360 image actually running on an instance must be a
# cosign-signed digest (signed by the CICD docker-release lifecycle). A tampered or unsigned image
# deployed on a cluster is caught here, not only at promotion.
#
# Reads image references on stdin, one per line, each a pinned digest
# (`ghcr.io/mairie360/<name>@sha256:...`); the caller (scripts/verify.sh, or by hand) produces them
# from the running pods. Only `${REGISTRY_PREFIX:-ghcr.io/mairie360/}` refs are checked; anything
# else (pause, probe, upstream public images) is listed as skipped. For each, `cosign verify` checks
# the signature against the signing workflow's identity and GitHub's OIDC issuer. Exit 1 if any
# mairie360 image is unsigned or fails verification, 0 otherwise.
#
#   kubectl -n mairie360-staging get pods -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' \
#     | SIGNER_IDENTITY_REGEXP='https://github.com/mairie360/.+/.github/workflows/.+@refs/heads/main' \
#       scripts/check-signed-images.sh
#
# SIGNER_IDENTITY_REGEXP must match docker-release's `signer_identity_regexp` (the identity that
# signed the images). cosign and a login to the registry are required; without cosign the check
# prints a notice and exits 0 (skipped), like the optional steps of verify.sh.
set -uo pipefail

PREFIX="${REGISTRY_PREFIX:-ghcr.io/mairie360/}"
ISSUER="${OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
IDENTITY="${SIGNER_IDENTITY_REGEXP:-https://github.com/mairie360/.+/.github/workflows/.+@refs/heads/main}"
COSIGN="${COSIGN:-cosign}"

if ! command -v "$COSIGN" >/dev/null 2>&1; then
  echo "cosign not found: image signature check skipped"
  exit 0
fi

ok()   { printf '  OK    %s\n' "$1"; }
ko()   { printf '  FAIL  %s\n' "$1"; FAILED=1; }
skip() { printf '  SKIP  %s\n' "$1"; }

FAILED=0
CHECKED=0
declare -A SEEN=()

while IFS= read -r ref; do
  ref="${ref#docker-pullable://}"   # kubectl imageID prefixes the pullable ref
  ref="${ref%%$'\r'}"
  [ -n "$ref" ] || continue
  case "$ref" in
    "$PREFIX"*"@sha256:"*) : ;;
    "$PREFIX"*) skip "no digest, cannot verify: $ref"; continue ;;
    *) skip "not a mairie360 image: $ref"; continue ;;
  esac
  [ -n "${SEEN[$ref]:-}" ] && continue
  SEEN[$ref]=1
  CHECKED=$((CHECKED + 1))
  if "$COSIGN" verify "$ref" \
       --certificate-oidc-issuer "$ISSUER" \
       --certificate-identity-regexp "$IDENTITY" >/dev/null 2>&1; then
    ok "signed: $ref"
  else
    ko "unsigned or invalid signature: $ref"
  fi
done

if [ "$CHECKED" -eq 0 ]; then
  echo "no mairie360 image digest on stdin"
fi
[ "$FAILED" -eq 0 ]
