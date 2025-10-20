#!/bin/bash
set -e

CHART_DIR="./mairie360"
CHART_NAME="mairie360"

# Liste des clusters et fichiers values
declare -A CLUSTERS
CLUSTERS=( ["dev"]="values-dev.yaml" ["staging"]="values-staging.yaml" ["prod"]="values-prod.yaml" )

# Créer les clusters Kind si nécessaire
for cluster in "${!CLUSTERS[@]}"; do
  if ! kind get clusters | grep -q "^$cluster$"; then
    echo "Création du cluster Kind $cluster"
    kind create cluster --name $cluster
  else
    echo "Cluster $cluster existe déjà"
  fi
done

# Déploiement sur chaque cluster
for cluster in "${!CLUSTERS[@]}"; do
  echo "Déploiement sur le cluster $cluster"
  kubectl config use-context "kind-$cluster"
  helm upgrade --install $CHART_NAME $CHART_DIR -f "$CHART_DIR/${CLUSTERS[$cluster]}"
done

echo "✅ Tous les clusters déployés"
