#!/bin/bash
set -e

# Nom du chart
CHART_NAME="mairie360"

# Namespaces à nettoyer
NAMESPACES=("dev" "staging" "prod")

echo "🚨 Suppression des déploiements Helm et des namespaces..."

for ns in "${NAMESPACES[@]}"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "⏳ Suppression de Helm release dans le namespace $ns..."
    helm uninstall "$CHART_NAME" -n "$ns" || echo "Aucune release Helm trouvée dans $ns"

    echo "⏳ Suppression du namespace $ns..."
    kubectl delete namespace "$ns" || echo "Impossible de supprimer le namespace $ns"
  else
    echo "Namespace $ns inexistant, rien à supprimer"
  fi
done

echo "✅ Tous les déploiements et namespaces supprimés"
