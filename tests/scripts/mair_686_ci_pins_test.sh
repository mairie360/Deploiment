#!/usr/bin/env bash
# MAIR-686: what the CI runs cannot change behind a moved tag or a replaced
# release asset.
#   - every third-party action is pinned by full commit SHA, with its tag in a
#     comment (`@<sha> # v7`); our own mairie360/* refs and ./ actions keep tags;
#   - cicd.yaml runs with a read-only token;
#   - every tool downloaded with curl is checked against a SHA256 before use:
#     no `curl | tar`, no `--verify=false`, one `sha256sum -c` per download.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOWS="$ROOT/.github/workflows"

FAILED=0
check() { if eval "$2"; then echo "  OK    $1"; else echo "  FAIL  $1"; FAILED=1; fi; }

unpinned=$(grep -nE '^[[:space:]]*(- )?uses:' "$WORKFLOWS"/*.y*ml \
  | grep -vE 'uses:[[:space:]]+(\./|mairie360/)' \
  | grep -vE '@[0-9a-f]{40} # v[0-9][^[:space:]]*[[:space:]]*$' || true)
[ -n "$unpinned" ] && echo "$unpinned"
check "third-party actions pinned by SHA with their tag in a comment" '[ -z "$unpinned" ]'

check "cicd.yaml: read-only token for every job" \
  'grep -Pzq "\npermissions:\n  contents: read\n" "$WORKFLOWS/cicd.yaml"'

check "no download piped into tar or a shell" \
  '! grep -nE "curl[^|]*\|[[:space:]]*(sudo )?(tar|sh|bash)" "$WORKFLOWS"/*.y*ml'
check "no plugin installed without verification" '! grep -n -- "--verify=false" "$WORKFLOWS"/*.y*ml'

for f in "$WORKFLOWS"/*.y*ml; do
  downloads=$(grep -cE '^[[:space:]]*curl .*-[a-zA-Z]*o[[:space:]]' "$f")
  checks=$(grep -cE 'sha256sum -c -' "$f")
  check "$(basename "$f"): $downloads download(s), each checked against a SHA256" "[ $downloads -eq $checks ]"
done
for name in KUBECONFORM HELM_UNITTEST KIND CILIUM_CLI CHAINSAW; do
  check "$name: SHA256 written in the workflow" \
    'grep -qE "^[[:space:]]*${name}_SHA256: [0-9a-f]{64}$" "$WORKFLOWS"/*.y*ml'
done

[ "$FAILED" -eq 0 ] && echo "MAIR-686: CI actions and tools pinned and verified"
exit "$FAILED"
