#!/bin/bash

# Couleurs pour la lisibilité
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}--- Démarrage de l'installation de l'environnement Mairie360 ---${NC}"

# 1. Téléchargement des outils (Kubectl & Kind)
echo -e "${GREEN}[1/5] Vérification/Installation des binaires...${NC}"

# Install Kubectl if missing
if ! command -v kubectl &> /dev/null; then
    sudo curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
fi

# Install Kind (Kubernetes in Docker) if missing
if ! command -v kind &> /dev/null; then
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
fi

# 2. Création du Cluster Kubernetes local
echo -e "${GREEN}[2/5] Création du cluster local (Kind)...${NC}"
if ! kind get clusters | grep -q "mairie360-cluster"; then
    kind create cluster --name mairie360-cluster
else
    echo "Le cluster existe déjà."
fi

# 3. Installation d'ArgoCD
echo -e "${GREEN}[3/5] Installation d'ArgoCD dans le cluster...${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Attente que les pods soient prêts
echo "En attente du démarrage d'ArgoCD (cela peut prendre 1-2 min)..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

# 4. Récupération du mot de passe Admin
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo -e "${BLUE}--------------------------------------------------${NC}"
echo -e "ArgoCD est installé !"
echo -e "Utilisateur : ${GREEN}admin${NC}"
echo -e "Mot de passe : ${GREEN}$PASS${NC}"
echo -e "${BLUE}--------------------------------------------------${NC}"

# 5. Exposition de l'interface ArgoCD
echo -e "${GREEN}[5/5] Exposition du serveur ArgoCD sur http://localhost:8080${NC}"
echo "Le script va maintenant garder la connexion ouverte. Appuyez sur Ctrl+C pour arrêter."

kubectl port-forward svc/argocd-server -n argocd 8080:443