#!/bin/bash
set -e

CHART_NAME="mairie360"
NAMESPACES=("dev" "staging" "prod")

echo "⚠️  Stopping and cleaning up Mairie360 local environment..."

# --- Loop through namespaces to clean up ---
for ns in "${NAMESPACES[@]}"; do
  echo "--- Checking namespace: $ns ---"

  # 1. Uninstall Helm Release
  if helm list -n "$ns" | grep -q "$CHART_NAME"; then
    echo "🧹 Uninstalling Helm release '$CHART_NAME' in '$ns'..."
    helm uninstall "$CHART_NAME" -n "$ns" --wait || echo "⚠️  Helm uninstall failed or timed out"
  else
    echo "ℹ️  No Helm release found in '$ns'"
  fi

  # 2. Force delete PVCs (Crucial for StatefulSets)
  # Helm doesn't delete PVCs created by volumeClaimTemplates to prevent data loss.
  # For a full reset, we manually wipe them.
  if kubectl get pvc -n "$ns" -l app.kubernetes.io/instance="$CHART_NAME" 2>/dev/null | grep -q "."; then
    echo "🔥 Deleting persistent volumes in '$ns' to allow a clean restart..."
    kubectl delete pvc -n "$ns" -l app.kubernetes.io/instance="$CHART_NAME" --grace-period=0 --force
  elif kubectl get pvc -n "$ns" 2>/dev/null | grep -q "database"; then
    echo "🔥 Deleting remaining database PVCs in '$ns'..."
    kubectl delete pvc -n "$ns" --all --grace-period=0 --force
  fi

  # 3. Delete Namespace
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "⏳ Deleting namespace '$ns'..."
    kubectl delete namespace "$ns" --grace-period=0 --force &
  else
    echo "ℹ️  Namespace '$ns' does not exist"
  fi
done

# Wait for background namespace deletions to finish
echo "⏳ Waiting for namespaces to be fully removed..."
wait

echo "✅ Cleanup complete. Your cluster is now empty and ready for a fresh 'deploy-single-cluster.sh'."