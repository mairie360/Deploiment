#!/bin/bash

# --- Configuration des Variables ---
# Nom du namespace où Vault sera déployé
NAMESPACE="vault-ns"
# Nom du release Helm (instance de Vault)
RELEASE_NAME="vault"

# --- 1. Création du Namespace dédié à Vault ---
echo "Création du namespace $NAMESPACE..."
kubectl create namespace $NAMESPACE

# --- 2. Ajout du dépôt Helm de HashiCorp ---
echo "Ajout du dépôt Helm HashiCorp..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# --- 3. Déploiement de Vault via Helm (Mode Dev/Non-HA) ---

# Nous utilisons ici un fichier de valeurs 'values-vault.yaml'
# pour configurer Vault spécifiquement pour un environnement de développement/projet.
echo "Déploiement de Vault (release $RELEASE_NAME) dans $NAMESPACE..."

helm install $RELEASE_NAME hashicorp/vault \
    --namespace $NAMESPACE \
    --values values-vault.yaml

# --- 4. Vérification du Déploiement ---
echo ""
echo "Vérification de l'état du Pod Vault (cela peut prendre quelques instants)..."
kubectl get pods --namespace $NAMESPACE -l app.kubernetes.io/name=vault

echo ""
echo "--- Déploiement Terminé ! ---"
echo "Vault est en cours de démarrage."
echo "Prochaine étape : voir les logs ou accéder à Vault."
