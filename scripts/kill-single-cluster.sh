#!/bin/bash
set -e

CHART_NAME="mairie360"
NAMESPACES=("dev" "staging" "prod")

echo "⚠️  Arrêt et nettoyage des déploiements Helm et Kubernetes"

for ns in "${NAMESPACES[@]}"; do
  echo "⏳ Tentative de désinstallation de la release $CHART_NAME dans le namespace $ns..."

  if helm list -n "$ns" | grep -q "$CHART_NAME"; then
    # Tente une désinstallation classique avec timeout étendu
    helm uninstall "$CHART_NAME" -n "$ns" --timeout 10m --wait || \
    echo "⚠️  La release $CHART_NAME n'a pas pu être désinstallée proprement dans $ns"
  else
    echo "ℹ️  La release $CHART_NAME n'existe pas dans $ns"
  fi

  echo "⏳ Suppression du namespace $ns..."
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl delete namespace "$ns" --grace-period=0 --force || \
    echo "⚠️  Le namespace $ns était déjà en cours de suppression"
  else
    echo "ℹ️  Le namespace $ns n'existe pas"
  fi
done

echo "✅ Nettoyage terminé"
