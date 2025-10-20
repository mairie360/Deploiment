#!/bin/bash
set -e

# Nom du chart
CHART_DIR="./mairie360"
CHART_NAME="mairie360"

# Vérifie si Minikube est lancé, sinon le démarre
if ! minikube status >/dev/null 2>&1; then
  echo "Démarrage de Minikube..."
  minikube start --driver=docker --memory=4g --cpus=2
fi

# Créer les namespaces si nécessaire
for ns in dev staging prod; do
  if ! kubectl get namespace $ns >/dev/null 2>&1; then
    echo "Création du namespace $ns"
    kubectl create namespace $ns
  else
    echo "Namespace $ns existe déjà"
  fi
done

# Déploiement dans chaque namespace avec son fichier values
echo "Déploiement Dev..."
helm upgrade --install $CHART_NAME $CHART_DIR -f $CHART_DIR/values-dev.yaml -n dev

# echo "Déploiement Staging..."
# helm upgrade --install $CHART_NAME $CHART_DIR -f $CHART_DIR/values-staging.yaml -n staging

# echo "Déploiement Prod..."
# helm upgrade --install $CHART_NAME $CHART_DIR -f $CHART_DIR/values-prod.yaml -n prod

echo "✅ Tous les environnements déployés dans un seul cluster"
