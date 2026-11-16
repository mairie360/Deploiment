#!/usr/bin/env bash
# =============================================================================
# List the restic snapshots of an instance's backup repository (MAIR-244).
#
#   ./scripts/list-snapshots.sh <kube-context> <env> [restic arguments...]
#   ./scripts/list-snapshots.sh mairie360-staging staging
#   ./scripts/list-snapshots.sh mairie360-staging staging snapshots --host <db-name> --json
#
# Without restic arguments it runs `restic snapshots`: every lineage of the
# repository (the Mairie360 database, `--host <POSTGRES_DB>`, and Keycloak's,
# `--host keycloak-<db-name>`). Any read-only restic command works the same way
# (`ls <id>`, `stats`, `check`); never `forget` / `prune` from here.
#
# Starts a throwaway pod (deleted on exit) built from the instance's backup
# CronJob (<env>-backup in mairie360-<env>): its restic image, its pod labels
# (the network policies already let them reach the bucket), its security
# context, its image pull secret and its AWS_* / RESTIC_* environment, which
# reads the keys from <env>-backup-secret. No secret goes through this
# machine. The disaster-recovery runbook (docs/en/disaster-recovery.md) uses it
# to pick the snapshot to restore.
#
# Needs: kubectl, jq. KUBECTL overrides the kubectl command.
# =============================================================================
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <kube-context> <env> [restic arguments...]" >&2
  exit 2
fi
ctx=$1 env=$2
shift 2
[ $# -gt 0 ] || set -- snapshots
ns="mairie360-$env"
read -r -a kubectl <<<"${KUBECTL:-kubectl}"
k() { "${kubectl[@]}" --context "$ctx" -n "$ns" "$@"; }

cronjob=$(k get cronjob "$env-backup" -o json) || {
  echo "no CronJob $env-backup in $ns: is backup.enabled true for this instance?" >&2
  exit 1
}

# restic's image entrypoint is restic: the pod args are the restic arguments,
# with --no-cache (read-only root filesystem, nothing kept between runs).
restic_args=$(jq -cn '$ARGS.positional' --args -- "$@")
overrides=$(jq -c --argjson args "$restic_args" '
  .spec.jobTemplate.spec.template as $t
  | ($t.spec.initContainers // [] | map(select(.name == "restic")) | first) as $restic
  | ($t.spec.containers | first) as $main
  | if $restic == null then error("no restic initContainer in the CronJob") else . end
  | {
      apiVersion: "v1",
      metadata: { labels: $t.metadata.labels },
      spec: {
        restartPolicy: "Never",
        automountServiceAccountToken: false,
        securityContext: $t.spec.securityContext,
        imagePullSecrets: ($t.spec.imagePullSecrets // []),
        volumes: [ { name: "tmp", emptyDir: { sizeLimit: "64Mi" } } ],
        containers: [ {
          name: "restic",
          image: $restic.image,
          args: ($args + ["--no-cache"]),
          env: (($main.env // [])
                | map(select(.name | test("^(AWS_[A-Z_]+|RESTIC_PASSWORD|RESTIC_REPOSITORY)$")))
                + [ { name: "HOME", value: "/tmp" } ]),
          securityContext: $restic.securityContext,
          volumeMounts: [ { name: "tmp", mountPath: "/tmp" } ]
        } ]
      }
    }' <<<"$cronjob")
image=$(jq -r '.spec.containers[0].image' <<<"$overrides")

k run "$env-backup-snapshots-$$" --rm -i --quiet --restart=Never \
  --image="$image" --overrides="$overrides" --pod-running-timeout=2m
