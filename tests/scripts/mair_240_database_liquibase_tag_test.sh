#!/usr/bin/env bash
# MAIR-240: the database image and the Liquibase migrations image are built
# together from Devops/Database, and the schema the migrations create must be
# the one the server image ships with (roles, extensions). Every instance, as
# the instances AppSet renders it, must therefore pin the same tag on both.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/charts/mairie360-stack"
FAILED=0
helm dependency build "$CHART" >/dev/null 2>&1 || { echo "helm dependency build failed" >&2; exit 1; }

tag_of() { # tag_of <instance dir> <template> <container image repository suffix>
  local values=()
  while IFS= read -r f; do values+=(-f "$f"); done < <("$ROOT/scripts/instance-values.sh" "$1")
  helm template r "$CHART" "${values[@]}" -s "$2" 2>/dev/null \
    | grep -E "^\s+image: \".*$3:" | head -1 | sed -E 's/.*:([^:"]+)".*/\1/'
}

statefulset_disabled() { # true when the instance runs Postgres on CloudNativePG only
  local values=()
  while IFS= read -r f; do values+=(-f "$f"); done < <("$ROOT/scripts/instance-values.sh" "$1")
  if helm template r "$CHART" "${values[@]}" -s charts/database/templates/cnpg-cluster.yaml >/dev/null 2>&1 \
     && ! helm template r "$CHART" "${values[@]}" -s charts/database/templates/statefulset.yaml >/dev/null 2>&1; then
    echo true
  else
    echo false
  fi
}

for dir in "$ROOT"/clusters/*/instances/*; do
  name="${dir#"$ROOT"/clusters/}"
  db="$(tag_of "$dir" charts/database/templates/statefulset.yaml '/database')"
  lq="$(tag_of "$dir" charts/liquibase/templates/job.yaml '/liquibase-migrations')"
  if [ -z "$db" ] && [ -n "$lq" ] && [ "$(statefulset_disabled "$dir")" = true ]; then
    # On CloudNativePG the server is the operator's official image: only the
    # migrations image carries the schema.
    echo "  SKIP  $name: no StatefulSet (CloudNativePG), liquibase on $lq"
  elif [ -z "$db" ] || [ -z "$lq" ]; then
    printf '  FAIL  %s: could not read the tags (database=%s liquibase=%s)\n' "$name" "$db" "$lq"; FAILED=1
  elif [ "$db" = "$lq" ]; then
    echo "  OK    $name: database and liquibase both on $db"
  else
    printf '  FAIL  %s: database is %s but liquibase is %s\n' "$name" "$db" "$lq"; FAILED=1
  fi
done
exit "$FAILED"
