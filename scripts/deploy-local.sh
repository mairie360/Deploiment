#!/bin/bash
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}--- Installation complète de l'environnement (Full Stack) ---${NC}"

# 1. Installation des binaires système
echo -e "${GREEN}[1/4] Installation Docker, Kind et Kubectl...${NC}"
sudo apt-get update && sudo apt-get install -y docker.io curl jq

if ! command -v kind &> /dev/null; then
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
fi

if ! command -v kubectl &> /dev/null; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x ./kubectl
    sudo mv ./kubectl /usr/local/bin/kubectl
fi

# 2. Lancement de Docker (si pas démarré)
sudo systemctl start docker

# 3. Création du Cluster Kind
echo -e "${GREEN}[2/4] Création du cluster Kind...${NC}"
if ! kind get clusters | grep -q "mairie360-cluster"; then
    kind create cluster --name mairie360-cluster
fi

# 4. Installation ArgoCD
echo -e "${GREEN}[3/4] Installation ArgoCD...${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side

echo "Attente du serveur ArgoCD..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

# 5. Récupération des accès
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo -e "${BLUE}--------------------------------------------------${NC}"
echo -e "Installation terminée avec succès."
echo -e "Password ArgoCD : ${GREEN}$PASS${NC}"
echo -e "${BLUE}--------------------------------------------------${NC}"
