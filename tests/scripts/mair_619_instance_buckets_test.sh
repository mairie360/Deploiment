#!/usr/bin/env bash
# MAIR-619: each instance uses its own buckets, the ones mairie360/Infra creates
# (modules/naming) and gives one key each: elearning-api's S3_BUCKET is
# <org-prefix>-elearning-<env>, never a bucket shared between instances (the
# hand-made mairie360-eleartning-storage was). The backup bucket is checked by
# mair_618_locked_backup_buckets_test.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/charts/mairie360-stack"
command -v helm >/dev/null || { echo "FAIL  helm is required"; exit 1; }
ls "$CHART"/charts/*.tgz >/dev/null 2>&1 || helm dependency build "$CHART" >/dev/null

failed=0
seen=""
for dir in "$ROOT"/clusters/*/instances/*/; do
  dir="${dir%/}"
  env="$(basename "$dir")"
  mapfile -t files < <("$ROOT/scripts/instance-values.sh" "$dir")
  args=()
  for f in "${files[@]}"; do args+=(-f "$f"); done
  bucket="$(helm template r "$CHART" "${args[@]}" -s charts/APIs/templates/deployment.yaml 2>/dev/null \
    | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Deployment" and d["metadata"]["name"].endswith("-elearning-api"):
        for e in d["spec"]["template"]["spec"]["containers"][0].get("env", []):
            if e["name"] == "S3_BUCKET":
                print(e["value"])
')"
  name="${dir#"$ROOT"/}"
  if [ -z "$bucket" ]; then
    echo "  SKIP  $name: no elearning-api"
  elif [[ ! "$bucket" =~ -elearning-${env}$ ]]; then
    echo "  FAIL  $name: S3_BUCKET $bucket is not the instance's <org>-elearning-$env"
    failed=1
  elif [[ " $seen " == *" $bucket "* ]]; then
    echo "  FAIL  $name: S3_BUCKET $bucket shared with another instance"
    failed=1
  else
    echo "  OK    $name: $bucket"
  fi
  seen="$seen $bucket"
done
exit $failed
