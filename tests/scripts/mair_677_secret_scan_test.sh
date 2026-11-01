#!/usr/bin/env bash
# MAIR-677: a GitHub PAT was committed in clear (pullSecretData, 446103e) and
# stayed readable in this public repo's history. The CI `secret-scan` job runs
# Gitleaks with .gitleaks.toml on every new commit: it must block a PAT or a
# plain Secret, including inside an instance's secrets.yaml, and must let the
# SealedSecret ciphertext written by scripts/seal-secrets.sh through.
# Needs docker (preinstalled on GitHub runners).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Same image as mairie360/CICD actions/security/gitleaks (bump both together).
IMAGE="zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"
FAILED=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Fake values built at runtime so this file itself never matches a rule.
fake_pat="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
sealed="Ag$(head -c 300 /dev/urandom | base64 -w0 | tr -d '\n' | cut -c1-400)"

scan() { # scan <expected: clean|leak> <label> <file> <content>
  local repo="$WORK/$RANDOM$RANDOM"
  mkdir -p "$repo/$(dirname "$3")"
  cp "$ROOT/.gitleaks.toml" "$repo/"
  printf '%s\n' "$4" > "$repo/$3"
  git -C "$repo" init -q
  git -C "$repo" -c user.name=t -c user.email=t@t add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qm test
  docker run --rm --user "$(id -u):$(id -g)" -v "$repo:/repo" -w /repo "$IMAGE" \
    git /repo --redact --no-banner --exit-code 1 >/dev/null 2>&1
  local rc=$? got
  if [ "$rc" -eq 0 ]; then got=clean; elif [ "$rc" -eq 1 ]; then got=leak; else got="error($rc)"; fi
  if [ "$got" = "$1" ]; then echo "  OK    $1: $2"; else echo "  FAIL  expected $1, got $got: $2"; FAILED=1; fi
}

SEALED_FILE=clusters/acme/instances/dev/secrets.yaml

scan leak "PAT in an instance's values.yaml (the 446103e leak)" \
  clusters/acme/instances/dev/values.yaml \
  "global:
  pullSecretToken: \"$fake_pat\""

scan clean "SealedSecret ciphertext in secrets.yaml" "$SEALED_FILE" \
  "extraObjects:
  - |
    kind: SealedSecret
    spec:
      encryptedData:
        JWT_SECRET: $sealed
        POSTGRES_PASSWORD: $sealed"

scan leak "PAT pasted into secrets.yaml next to sealed values" "$SEALED_FILE" \
  "extraObjects:
  - |
    kind: SealedSecret
    spec:
      encryptedData:
        JWT_SECRET: $sealed
        GHCR_TOKEN: $fake_pat"

scan leak "PAT in chart values (no allowlist outside secrets.yaml)" \
  charts/mairie360-stack/values.yaml \
  "apiKey: \"$fake_pat\""

exit "$FAILED"
