#!/usr/bin/env bash
# =============================================================================
# End-to-end test of the Kubernetes layer (not of the application).
#
#   tests/e2e/run.sh            create the cluster, install, test, delete it
#   INSTANCE=dev … run.sh       same, but with the REAL images and env vars of
#                               clusters/mairie360/instances/dev (also
#                               INSTANCE=client-example/prod). Slower, and the
#                               apps really have to start.
#   KEEP=1 tests/e2e/run.sh     keep the cluster afterwards (debugging);
#                               a second run reuses it and reinstalls the chart
#
# 1. Kind cluster with Cilium, the CNI of the real machines, so the
#    NetworkPolicies are enforced exactly like in production.
# 2. `helm install --wait --wait-for-jobs` of charts/mairie360-stack with
#    tests/e2e/values.yaml (placeholder app images, real data layer), or with
#    an instance's values plus tests/e2e/values-real.yaml when INSTANCE is set.
# 3. `helm test` (the chart's own test pods).
# 4. Chainsaw tests in tests/e2e/chainsaw/.
#
# Needs: docker, kind, kubectl, helm, cilium (CLI), chainsaw, jq.
# Same script locally and in CI (.github/workflows/k8s-e2e.yaml).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLUSTER="${CLUSTER:-mairie360-e2e}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.31.14}"   # k3s channel v1.31 on the machines
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"           # ansible group_vars/all.yml
NAMESPACE=mairie360-e2e
RELEASE=e2e
CTX="kind-$CLUSTER"
K="kubectl --context $CTX"

# Placeholder images by default; INSTANCE=<env> or <org>/<env> deploys that
# instance's real values with only credentials and storage overridden.
if [ -n "${INSTANCE:-}" ]; then
  case "$INSTANCE" in */*) ORG=${INSTANCE%%/*}; ENV=${INSTANCE##*/};; *) ORG=mairie360; ENV=$INSTANCE;; esac
  INSTANCE_VALUES="$ROOT/clusters/$ORG/instances/$ENV/values.yaml"
  [ -f "$INSTANCE_VALUES" ] || { echo "no such instance: $INSTANCE_VALUES" >&2; exit 1; }
  # On a real instance the database name comes from the sealed Secret, which
  # scripts/seal-secrets.sh builds as mairie_db_<env> — the same rule has to
  # apply here, or Liquibase connects to a database that does not exist.
  VALUES=(-f "$INSTANCE_VALUES" -f "$HERE/values-real.yaml"
          --set "database.env.POSTGRES_DB=mairie_db_${ENV}")
  INSTALL_TIMEOUT=20m
else
  VALUES=(-f "$HERE/values.yaml")
  INSTALL_TIMEOUT=10m
fi
# One more values file, last: try a candidate image tag or an extra env var
# without editing anything tracked.
[ -n "${EXTRA_VALUES:-}" ] && VALUES+=(-f "$EXTRA_VALUES")

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

for bin in docker kind kubectl helm cilium chainsaw jq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done

dump() {
  step "Diagnostics"
  $K -n "$NAMESPACE" get pods,jobs,networkpolicies -o wide || true
  $K -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -40 || true
  for pod in $($K -n "$NAMESPACE" get pods --no-headers 2>/dev/null \
               | awk '$3 != "Running" && $3 != "Completed" {print $1}'); do
    $K -n "$NAMESPACE" describe pod "$pod" | tail -25 || true
    $K -n "$NAMESPACE" logs "$pod" --all-containers --tail=40 || true
  done
  # A Job past its backoffLimit has its pods deleted, logs included: run it
  # once more, without retries, to show why it fails.
  for job in $($K -n "$NAMESPACE" get jobs -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    echo "--- rerun of failed Job $job"
    $K -n "$NAMESPACE" get job "$job" -o json | jq '
      {apiVersion, kind,
       metadata: {name: (.metadata.name + "-debug")},
       spec: (.spec | del(.selector) | .backoffLimit = 0
              | .template.metadata.labels |= with_entries(select(.key | startswith("app.kubernetes.io/")))
              | .template.spec.restartPolicy = "Never")}' \
      | $K -n "$NAMESPACE" apply -f - >/dev/null || continue
    $K -n "$NAMESPACE" wait "job/$job-debug" --for=condition=complete --for=condition=failed --timeout=5m >/dev/null || true
    $K -n "$NAMESPACE" logs "job/$job-debug" --all-containers --tail=60 || true
  done
  $K -n kube-system exec ds/cilium -c cilium-agent -- \
    hubble observe --verdict DROPPED --last 50 || true
}

cleanup() {
  rc=$?
  [ "$rc" -ne 0 ] && dump
  if [ "${KEEP:-0}" = 1 ]; then
    echo "cluster kept: kubectl --context $CTX -n $NAMESPACE get pods"
  else
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT

step "Cluster $CLUSTER"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "reusing the existing cluster"
else
  kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" \
    --config "$HERE/kind-config.yaml" --wait 0s
fi

step "Cilium $CILIUM_VERSION"
if ! $K -n kube-system get ds cilium >/dev/null 2>&1; then
  cilium install --context "$CTX" --version "$CILIUM_VERSION" \
    --values "$HERE/cilium-values.yaml"
fi
cilium status --context "$CTX" --wait --wait-duration 5m >/dev/null
$K wait --for=condition=Ready node --all --timeout=3m

step "Install: data layer and migrations (sync waves 0-1)${INSTANCE:+ — real images of instance $INSTANCE}"
helm dependency build "$ROOT/charts/mairie360-stack" >/dev/null
# Start from an empty namespace: leftovers of a kept cluster would hide a
# broken install (and Postgres only reads its passwords on first init).
helm --kube-context "$CTX" uninstall "$RELEASE" -n "$NAMESPACE" --wait >/dev/null 2>&1 || true
$K delete namespace "$NAMESPACE" --wait >/dev/null 2>&1 || true
# In two phases, because `helm install` ignores the Argo CD sync waves and
# would start the APIs before the database: they exit, and a real app then
# sits in CrashLoopBackOff for reasons that never happen on a real sync.
# Phase 1 = waves 0-1 (data + migrations), phase 2 = waves 2-4 (apps), which
# also exercises `helm upgrade` on an existing release.
NO_APPS=(--set APIs.instances=null --set BFFs.instances=null --set Fronts.instances=null)
helm --kube-context "$CTX" install "$RELEASE" "$ROOT/charts/mairie360-stack" \
  -n "$NAMESPACE" --create-namespace \
  "${VALUES[@]}" "${NO_APPS[@]}" \
  --wait --wait-for-jobs --timeout "$INSTALL_TIMEOUT"

step "Upgrade: APIs, BFFs and fronts (sync waves 2-4)"
helm --kube-context "$CTX" upgrade "$RELEASE" "$ROOT/charts/mairie360-stack" \
  -n "$NAMESPACE" \
  "${VALUES[@]}" \
  --wait --wait-for-jobs --timeout "$INSTALL_TIMEOUT"

step "helm test"
helm --kube-context "$CTX" test "$RELEASE" -n "$NAMESPACE" --logs --timeout 3m

step "Chainsaw"
chainsaw test \
  --kube-context "$CTX" \
  --config "$HERE/chainsaw/.chainsaw.yaml" \
  --test-dir "$HERE/chainsaw"
