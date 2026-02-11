#!/bin/bash
set -e

echo "--- Déploiement Kubernetes & ArgoCD uniquement ---"

# 1. Cluster
if ! kind get clusters | grep -q "mairie360-cluster"; then
    kind create cluster --name mairie360-cluster
fi

# 2. ArgoCD
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side

# 3. Status
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

echo "Cluster prêt et ArgoCD installé."
