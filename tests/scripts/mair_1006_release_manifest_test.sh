#!/usr/bin/env bash
# MAIR-1006: a release is defined by releases/<version>.yaml, the commit of each repo's main frozen
# at the start. scripts/release-manifest.py must build it from main (journal commits left out),
# refuse an invalid manifest, and with --remote a sha that is not on its repo's main.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/release-manifest.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/out"

# Fake gh: main of every repo = [journal commit, aaaa…]; compare answers "behind" for bbbb….
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$2" in
  *"/commits?sha=main"*)
    printf '[{"sha":"%s","commit":{"message":"docs(release-journal): dev x [skip ci]"}},{"sha":"%s","commit":{"message":"feat: y\\n\\nbody"}}]' \
      "$(printf 'f%.0s' {1..40})" "$(printf 'a%.0s' {1..40})" ;;
  *"/compare/bbbb"*) echo '{"status":"behind"}' ;;
  *"/compare/cccc"*) echo '{"message":"Not Found"}' >&2; exit 1 ;;
  *"/compare/"*) echo '{"status":"identical"}' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

FAILED=0
ok() { echo "  OK    $1"; }
ko() { echo "  FAIL  $1"; FAILED=1; }
expect_exit() { # expect_exit <code> <description> <args...>
  local want=$1 what=$2; shift 2
  "$SCRIPT" "$@" > "$TMP/last.log" 2>&1; local got=$?
  if [ "$got" = "$want" ]; then ok "$what (exit $got)"; else ko "$what: expected exit $want, got $got"; cat "$TMP/last.log"; fi
}

expect_exit 0 "new builds a manifest" new 1.0.0 --out "$TMP/out"
M="$TMP/out/1.0.0.yaml"
if grep -q "sha: $(printf 'a%.0s' {1..40})" "$M" && ! grep -q ffffffff "$M"; then ok "journal commit left out"; else ko "journal commit left out"; fi
if [ "$(grep -c '^  [A-Za-z_]*:$' "$M")" = 22 ]; then ok "22 repos"; else ko "22 repos"; fi
grep -q "dev_tag: dev-aaaaaaa" "$M" && ok "dev tag" || ko "dev tag"
expect_exit 2 "new never rewrites a manifest" new 1.0.0 --out "$TMP/out"
expect_exit 0 "check accepts it" check "$M"
expect_exit 0 "check --remote accepts shas on main" check --remote "$M"

sed 's/^version: .*/version: "1.0.1"/' "$M" > "$TMP/out/1.0.0-wrong.yaml"
expect_exit 1 "file name must match the version" check "$TMP/out/1.0.0-wrong.yaml"
python3 - "$M" "$TMP/out/missing/1.0.0.yaml" <<'PY'
import sys, yaml, os
m = yaml.safe_load(open(sys.argv[1])); del m["repos"]["Settings_Web_Service"]
os.makedirs(os.path.dirname(sys.argv[2])); yaml.safe_dump(m, open(sys.argv[2], "w"))
PY
expect_exit 1 "a missing repo is refused" check "$TMP/out/missing/1.0.0.yaml"
python3 - "$M" "$TMP/out/tag/1.0.0.yaml" <<'PY'
import sys, yaml, os
m = yaml.safe_load(open(sys.argv[1])); m["repos"]["Core_API"]["dev_tag"] = "dev-1234567"; m["repos"]["BFF_user"]["semver"] = "latest"
os.makedirs(os.path.dirname(sys.argv[2])); yaml.safe_dump(m, open(sys.argv[2], "w"))
PY
expect_exit 1 "dev_tag and semver are checked" check "$TMP/out/tag/1.0.0.yaml"
for case in b:behind c:unknown; do
  letter=${case%%:*}
  python3 - "$M" "$TMP/out/$letter/1.0.0.yaml" "$letter" <<'PY'
import sys, yaml, os
m = yaml.safe_load(open(sys.argv[1])); sha = sys.argv[3] * 40
m["repos"]["Core_API"].update(sha=sha, dev_tag="dev-" + sha[:7])
os.makedirs(os.path.dirname(sys.argv[2])); yaml.safe_dump(m, open(sys.argv[2], "w"))
PY
  expect_exit 0 "format of a ${case#*:} sha is valid offline" check "$TMP/out/$letter/1.0.0.yaml"
  expect_exit 1 "--remote refuses a ${case#*:} sha" check --remote "$TMP/out/$letter/1.0.0.yaml"
done
expect_exit 0 "the committed manifests are valid" check

exit $FAILED
