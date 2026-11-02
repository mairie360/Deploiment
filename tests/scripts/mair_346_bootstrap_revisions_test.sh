#!/usr/bin/env bash
# MAIR-346: the root `platform` Application applies bootstrap/appsets/ from
# `main` to every machine at once, so a chart version or a revision written in
# an instance AppSet would reach prod on merge, skipping staging.
# scripts/check-bootstrap-revisions.sh must pass on the repo and refuse each
# way of bringing that back (on a throwaway copy of bootstrap/).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/check-bootstrap-revisions.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILED=0
expect() { # expect <pass|fail> <description> <bootstrap dir>
  local got=pass
  "$SCRIPT" "$3" >/dev/null 2>&1 || got=fail
  if [ "$got" = "$1" ]; then echo "  OK    $2: $got"; else echo "  FAIL  $2: expected $1, got $got"; FAILED=1; fi
}
# mutate <name> <file under bootstrap/> <python expression on s>: copy of
# bootstrap/ with one file rewritten, prints its path.
mutate() {
  local dir="$TMP/$1"
  cp -r "$ROOT/bootstrap" "$dir"
  python3 - "$dir/$2" "$3" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
new = eval(expr)
assert new != s, "mutation changed nothing"
open(p, "w").write(new)
PY
  echo "$dir"
}

expect pass "the repository's bootstrap/" "$ROOT/bootstrap"

expect fail "traefik read from its Helm repository again" "$(mutate chart appsets/traefik-appset.yaml \
  "s.replace('repoURL: https://github.com/mairie360/Deploiment.git', 'repoURL: https://traefik.github.io/charts\n        chart: traefik').replace(\"targetRevision: '{{ .values.revision }}'\", 'targetRevision: 41.6.0')")"

expect fail "cert-manager pinned to main" "$(mutate main appsets/cert-manager-appset.yaml \
  "s.replace(\"targetRevision: '{{ .values.revision }}'\", 'targetRevision: main')")"

expect fail "sealed-secrets revision not read from the cluster annotation" "$(mutate annotation appsets/sealed-secrets-appset.yaml \
  "s.replace('index .metadata.annotations \"mairie360.fr/revision\"', 'index .metadata.labels \"mairie360.fr/env\"')")"

expect fail "cluster-issuers without goTemplate" "$(mutate gotemplate appsets/cluster-issuer-appset.yaml \
  "s.replace('  goTemplate: true\n', '')")"

expect fail "ingress-nginx read outside bootstrap/" "$(mutate path appsets/ingress-nginx-appset.yaml \
  "s.replace('path: bootstrap/addons/ingress-nginx', 'path: charts/ingress-nginx')")"

expect fail "an IP in cert-manager's values (MAIR-157)" "$(mutate ip addons/cert-manager/values.yaml \
  "s + '\n# dns01 resolver 51.15.0.1\n'")"

# The revision expression itself, evaluated with Helm's Go template + sprig
# engine (Argo CD's goTemplate has the same `default`, `index`): the
# annotation when present, `main` when the cluster has no annotation at all or
# not this one.
EXPRS=$(python3 - "$ROOT/bootstrap/appsets" <<'PY'
import glob, sys, yaml
for p in sorted(glob.glob(sys.argv[1] + "/*.yaml")):
    for d in yaml.safe_load_all(open(p)):
        for g in ((d or {}).get("spec") or {}).get("generators") or []:
            r = ((g.get("clusters") or {}).get("values") or {}).get("revision")
            if r:
                print(r)
PY
)
mkdir -p "$TMP/expr/templates"
printf 'apiVersion: v2\nname: expr\nversion: 0.1.0\n' > "$TMP/expr/Chart.yaml"
while IFS= read -r e; do
  printf 'kind: ConfigMap\nrev: "{{ with .Values.cluster }}%s{{ end }}"\n' "$e" > "$TMP/expr/templates/r.yaml"
  for c in "staging|--set-string cluster.metadata.annotations.mairie360\\.fr/revision=staging" \
           "main|--set-string cluster.metadata.annotations.other=x" \
           "main|--set-string cluster.metadata.name=x"; do
    want=${c%%|*}
    # shellcheck disable=SC2086 # the --set-string flag is split on purpose
    got=$(helm template e "$TMP/expr" ${c#*|} 2>&1 | sed -n 's/^rev: "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')
    if [ "$got" = "$want" ]; then echo "  OK    revision expression (${c#*cluster.}): $got"
    else echo "  FAIL  revision expression (${c#*cluster.}): expected $want, got $got"; FAILED=1; fi
  done
done <<<"$(echo "$EXPRS" | sort -u)"

exit "$FAILED"
