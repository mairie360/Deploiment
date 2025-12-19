#!/bin/bash
set -e

CHART_NAME="mairie360"
VAULT_RELEASE_NAME="vault"
# Ajout de la variable pour le CSI Driver/Secrets Operator
CSI_RELEASE_NAME="vault-secrets-operator" 
NAMESPACES=("dev" "staging" "prod")

# --- Choix du binaire kubectl compatible Minikube ---
KUBECTL_CMD="kubectl"
if minikube status >/dev/null 2>&1; then
    # S'assurer que KUBECTL_CMD est la commande complète si Minikube est utilisé
    KUBECTL_CMD="minikube kubectl --"
fi

echo "⚠️  Arrêt et nettoyage des déploiements Helm et Kubernetes..."

# --- Suppression des releases mairie360 dans chaque namespace ---
# NOTE : Cette section est commentée pour l'instant car elle ne correspond pas
# à l'état actuel de votre script de déploiement (les applications sont commentées).
# Décommentez cette section lorsque vous commencerez à déployer vos applications.

# for ns in "${NAMESPACES[@]}"; do
#   echo "⏳ Tentative de désinstallation de la release $CHART_NAME dans le namespace $ns..."
# 
#   if helm list -n "$ns" | grep -q "$CHART_NAME"; then
#     echo "🧹 Désinstallation de $CHART_NAME dans $ns..."
#     helm uninstall "$CHART_NAME" -n "$ns" --timeout 10m --wait || \
#       echo "⚠️  La release $CHART_NAME n'a pas pu être désinstallée proprement dans $ns"
#   else
#     echo "ℹ️  La release $CHART_NAME n'existe pas dans $ns"
#   fi
# 
#   echo "⏳ Suppression du namespace $ns..."
#   if $KUBECTL_CMD get namespace "$ns" >/dev/null 2>&1; then
#     $KUBECTL_CMD delete namespace "$ns" --grace-period=0 --force || \
#       echo "⚠️  Le namespace $ns était déjà en cours de suppression"
#   else
#     echo "ℹ️  Le namespace $ns n'existe pas"
#   fi
# done


# --- Suppression du Vault CSI Driver / Secrets Operator ---
echo "⏳ Vérification de la présence du Vault CSI Driver ($CSI_RELEASE_NAME)..."

# Correction : Utilisation de '|| true' pour éviter le crash de 'set -e' si grep ne trouve rien
CSI_LINE=$(helm list -A | grep "^$CSI_RELEASE_NAME\s" || true) 

if [ -n "$CSI_LINE" ]; then
  CSI_NS=$(echo "$CSI_LINE" | awk '{print $2}')
  echo "🧹 Désinstallation du Vault CSI Driver dans le namespace $CSI_NS..."
  helm uninstall "$CSI_RELEASE_NAME" -n "$CSI_NS" --timeout 5m --wait || \
    echo "⚠️  Impossible de désinstaller le Vault CSI Driver proprement"
else
  echo "ℹ️  Vault CSI Driver n'est pas installé sur ce cluster"
fi


# --- Suppression de Vault ---
echo "⏳ Vérification de la présence de Vault ($VAULT_RELEASE_NAME)..."
# Correction : Utilisation de '|| true' pour éviter le crash de 'set -e' si grep ne trouve rien
VAULT_LINE=$(helm list -A | grep "^$VAULT_RELEASE_NAME\s" || true)

if [ -n "$VAULT_LINE" ]; then
  VAULT_NS=$(echo "$VAULT_LINE" | awk '{print $2}')
  echo "🧹 Désinstallation de Vault dans le namespace $VAULT_NS..."
  
  # Désinstallation Helm
  helm uninstall "$VAULT_RELEASE_NAME" -n "$VAULT_NS" --timeout 5m --wait || \
    echo "⚠️  Impossible de désinstaller Vault proprement"

  # NOUVEAU : Suppression forcée du Pod vault-0 si Helm ne l'a pas fait rapidement
  if $KUBECTL_CMD get pod vault-0 -n default >/dev/null 2>&1; then
      echo "🔥 Suppression forcée du Pod vault-0 (pour régler l'état Terminating)..."
      # Supprime la ressource pod directement
      $KUBECTL_CMD delete pod vault-0 -n default --grace-period=0 --force
  fi
  # FIN NOUVEAU

  # La suppression du namespace n'est pas nécessaire car Vault est dans 'default'
  if [ "$VAULT_NS" != "default" ]; then
    echo "ℹ️ Vault était dans un namespace dédié. La suppression des namespaces d'applications est commentée."
  else
    echo "ℹ️ Vault est dans le namespace 'default' (non supprimé)."
  fi
else
  echo "ℹ️  Vault n'est pas installé sur ce cluster"
fi

# --- Nettoyage final ---
echo "✅ Nettoyage terminé"
echo "📋 État actuel des releases Helm :"
helm list -A || echo "Aucune release Helm trouvée"