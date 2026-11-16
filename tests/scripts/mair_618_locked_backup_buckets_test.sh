#!/usr/bin/env bash
# MAIR-618: every instance backs up into its locked bucket <org-prefix>-backups-<env>,
# created by mairie360/Infra (modules/instance/backup.tf: versioning + COMPLIANCE
# object lock), never into the hand-made unlocked <org-prefix>-backup-<env> ones.
# Renders each instance (scripts/instance-values.sh order) and checks the backup
# CronJob's RESTIC_REPOSITORY.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/charts/mairie360-stack"
command -v helm >/dev/null || { echo "FAIL  helm is required"; exit 1; }
[ -d "$CHART/charts" ] && ls "$CHART"/charts/*.tgz >/dev/null 2>&1 || helm dependency build "$CHART" >/dev/null

failed=0
for dir in "$ROOT"/clusters/*/instances/*/; do
  dir="${dir%/}"
  env="$(basename "$dir")"
  mapfile -t files < <("$ROOT/scripts/instance-values.sh" "$dir")
  args=()
  for f in "${files[@]}"; do args+=(-f "$f"); done
  repo="$(helm template r "$CHART" "${args[@]}" -s charts/backup/templates/cronjob.yaml 2>/dev/null \
    | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "CronJob":
        for e in d["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["env"]:
            if e["name"] == "RESTIC_REPOSITORY":
                print(e["value"])
')"
  if [ -z "$repo" ]; then
    echo "  SKIP  ${dir#"$ROOT"/}: backup disabled"
  elif [[ "$repo" =~ -backups-${env}$ ]]; then
    echo "  OK    ${dir#"$ROOT"/}: $repo"
  else
    echo "  FAIL  ${dir#"$ROOT"/}: $repo is not the locked <org>-backups-$env bucket"
    failed=1
  fi
done
exit $failed
