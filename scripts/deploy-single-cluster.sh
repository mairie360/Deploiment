#!/bin/bash
set -e

# Nom du chart
CHART_DIR="./mairie360"
CHART_NAME="mairie360"

# Charger les variables d'environnement depuis .env s'il existe
if [ -f ".env" ]; then
  echo "Chargement des variables d'environnement depuis .env..."
  export $(grep -v '^#' .env | xargs)
else
  echo "⚠️  Aucun fichier .env trouvé. Assure-toi que les variables GHCR_* sont définies."
fi

# Vérification des variables nécessaires
if [ -z "$GHCR_USERNAME" ] || [ -z "$GHCR_TOKEN" ] || [ -z "$GHCR_EMAIL" ]; then
  echo "❌ Erreur : il manque au moins une des variables suivantes : GHCR_USERNAME, GHCR_TOKEN, GHCR_EMAIL"
  exit 1
fi

GHCR_SERVER="ghcr.io"
GHCR_SECRET_NAME="ghcr-secret"

# Vérifie si Minikube est lancé, sinon le démarre
if ! minikube status >/dev/null 2>&1; then
  echo "Démarrage de Minikube..."
  minikube start --driver=docker --memory=4g --cpus=2
fi

# Création des namespaces et secrets
for ns in dev staging prod; do
  if ! kubectl get namespace $ns >/dev/null 2>&1; then
    echo "Création du namespace $ns"
    kubectl create namespace $ns
  else
    echo "Namespace $ns existe déjà"
  fi

  # Création du secret si non existant
  if ! kubectl get secret $GHCR_SECRET_NAME -n $ns >/dev/null 2>&1; then
    echo "Création du secret $GHCR_SECRET_NAME dans le namespace $ns..."
    kubectl create secret docker-registry $GHCR_SECRET_NAME \
      --docker-server=$GHCR_SERVER \
      --docker-username=$GHCR_USERNAME \
      --docker-password=$GHCR_TOKEN \
      --docker-email=$GHCR_EMAIL \
      -n $ns
  else
    echo "Secret $GHCR_SECRET_NAME déjà présent dans le namespace $ns"
  fi
done

# Déploiement dans chaque namespace avec son fichier values
echo "Déploiement Dev..."
helm upgrade --install $CHART_NAME $CHART_DIR -f $CHART_DIR/values-dev.yaml -n dev

echo "Déploiement Staging..."
helm upgrade --install $CHART_NAME $CHART_DIR -f $CHART_DIR/values-staging.yaml -n staging

echo "Déploiement Prod..."
helm upgrade --install $CHART_NAME $CHART_DIR -f $CHART_DIR/values-prod.yaml -n prod

echo "✅ Tous les environnements déployés dans un seul cluster"
