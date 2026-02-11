#!/bin/bash
set -e

NAMESPACES=("dev" "staging" "prod" "argocd")

echo "⚠️  Stopping and cleaning up Mairie360 ArgoCD environment..."

# --- 1. SUPPRESSION DU ROOT APP ET DES APPS ARGO ---
# On commence par supprimer l'application "mère".
# ArgoCD supprimera automatiquement toutes les sous-applications (cascade deletion).
if kubectl get application root-app -n argocd >/dev/null 2>&1; then
  echo "🧹 Deleting ArgoCD Root Application (this will trigger cascading cleanup)..."
  kubectl delete application root-app -n argocd --timeout=60s || echo "⚠️  Root-app deletion timed out"
fi

# --- 2. NETTOYAGE DES NAMESPACES ---
for ns in "${NAMESPACES[@]}"; do
  echo "--- Checking namespace: $ns ---"

  # Vérifier si le namespace existe
  if kubectl get namespace "$ns" >/dev/null 2>&1; then

    # 2a. Suppression spécifique des PVCs (Argo ne les supprime pas par défaut)
    echo "🔥 Wiping all PVCs in '$ns' to ensure a clean slate..."
    kubectl delete pvc --all -n "$ns" --grace-period=0 --force 2>/dev/null || true

    # 2b. Suppression du Namespace
    # Note : On ne met pas argocd en arrière-plan pour être sûr qu'il est mort avant de finir
    echo "⏳ Deleting namespace '$ns'..."
    kubectl delete namespace "$ns" --grace-period=0 --force &
  else
    echo "ℹ️  Namespace '$ns' does not exist"
  fi
done

# --- 3. ATTENTE ET FINALISATION ---
echo "⏳ Waiting for all deletions to complete (this can take a moment)..."
wait

# Un petit coup de balai sur les résidus potentiels d'Argo (CRDs)
if [ "$1" == "--full" ]; then
  echo "🛡️  Option --full detected: Removing ArgoCD CRDs..."
  kubectl get crd | grep "argoproj.io" | awk '{print $1}' | xargs -r kubectl delete crd
fi

echo "✅ Cleanup complete. Your cluster is ready for a fresh 'local-deploy.sh'."
