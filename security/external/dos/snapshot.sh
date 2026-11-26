#!/usr/bin/env bash
# Capture the cluster-side evidence of a denial-of-service scenario. RUN ON THE ARGO CD
# MACHINE (the only one that reaches the staging API server, like verify.sh), into the same
# per-scenario directory the source machine writes to:
#
#   KUBECONFIG=/home/gh-runner/.kube/instance-staging.yaml ./snapshot.sh before report/http-burst-login
#   # ... attack runs ...
#   KUBECONFIG=... ./snapshot.sh after  report/http-burst-login
#   KUBECONFIG=... ./snapshot.sh recovery report/http-burst-login   # polls until every pod is Ready
set -euo pipefail
PHASE=${1:?before|after|recovery}
DIR=${2:?scenario directory}
NS=${NAMESPACE:-mairie360-staging}
mkdir -p "$DIR"

case "$PHASE" in
  before) kubectl -n "$NS" get pods -o json > "$DIR/pods-before.json" ;;
  after)
    kubectl -n "$NS" get pods -o json > "$DIR/pods-after.json"
    kubectl -n "$NS" top pods --no-headers > "$DIR/top-after.txt" ;;
  recovery)
    start=$(date +%s)
    deadline=$((start + ${RECOVERY_TIMEOUT:-600}))
    while :; do
      not_ready=$(kubectl -n "$NS" get pods --no-headers \
        | awk '{split($2,a,"/"); if (a[1] != a[2] || $3 != "Running") c++} END {print c+0}')
      now=$(date +%s)
      if [ "$not_ready" -eq 0 ]; then
        printf '{"recovered_after_seconds": %d}\n' "$((now - start))" > "$DIR/recovery.json"
        break
      fi
      if [ "$now" -ge "$deadline" ]; then
        echo '{"recovered_after_seconds": null}' > "$DIR/recovery.json"
        break
      fi
      sleep 5
    done ;;
  *) echo "unknown phase $PHASE" >&2; exit 2 ;;
esac
