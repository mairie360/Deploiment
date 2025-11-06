#!/bin/bash
set -e

CHART_NAME="mairie360"
VAULT_RELEASE_NAME="vault"
NAMESPACES=("dev" "staging" "prod")

# --- Choix du binaire kubectl compatible Minikube ---
KUBECTL_CMD="kubectl"
if minikube status >/dev/null 2>&1; then
    KUBECTL_CMD="minikube kubectl --"
fi

echo "⚠️  Arrêt et nettoyage des déploiements Helm et Kubernetes..."

# --- Suppression des releases mairie360 dans chaque namespace ---
for ns in "${NAMESPACES[@]}"; do
  echo "⏳ Tentative de désinstallation de la release $CHART_NAME dans le namespace $ns..."

  if helm list -n "$ns" | grep -q "$CHART_NAME"; then
    echo "🧹 Désinstallation de $CHART_NAME dans $ns..."
    helm uninstall "$CHART_NAME" -n "$ns" --timeout 10m --wait || \
      echo "⚠️  La release $CHART_NAME n'a pas pu être désinstallée proprement dans $ns"
  else
    echo "ℹ️  La release $CHART_NAME n'existe pas dans $ns"
  fi

  echo "⏳ Suppression du namespace $ns..."
  if $KUBECTL_CMD get namespace "$ns" >/dev/null 2>&1; then
    $KUBECTL_CMD delete namespace "$ns" --grace-period=0 --force || \
      echo "⚠️  Le namespace $ns était déjà en cours de suppression"
  else
    echo "ℹ️  Le namespace $ns n'existe pas"
  fi
done

# --- Suppression de Vault ---
echo "⏳ Vérification de la présence de Vault..."
VAULT_LINE=$(helm list -A | grep "^$VAULT_RELEASE_NAME\s")
if [ -n "$VAULT_LINE" ]; then
  VAULT_NS=$(echo "$VAULT_LINE" | awk '{print $2}')
  echo "🧹 Désinstallation de Vault dans le namespace $VAULT_NS..."
  helm uninstall "$VAULT_RELEASE_NAME" -n "$VAULT_NS" --timeout 5m --wait || \
    echo "⚠️  Impossible de désinstaller Vault proprement"

  # Ne jamais tenter de supprimer le namespace 'default'
  if [ "$VAULT_NS" != "default" ]; then
    echo "⏳ Suppression du namespace $VAULT_NS..."
    if $KUBECTL_CMD get namespace "$VAULT_NS" >/dev/null 2>&1; then
      $KUBECTL_CMD delete namespace "$VAULT_NS" --grace-period=0 --force || \
        echo "⚠️  Le namespace $VAULT_NS était déjà en cours de suppression"
    fi
  else
    echo "ℹ️  Namespace $VAULT_NS ne peut pas être supprimé (default)"
  fi
else
  echo "ℹ️  Vault n'est pas installé sur ce cluster"
fi

# --- Nettoyage final ---
echo "✅ Nettoyage terminé"
echo "📋 État actuel des releases Helm :"
helm list -A || echo "Aucune release Helm trouvée"
