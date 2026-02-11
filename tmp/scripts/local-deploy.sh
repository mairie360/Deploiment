#!/bin/bash
set -e

# --- 1. INFRASTRUCTURE & LOCAL MOUNT ---
REPO_PATH=$(pwd)
MOUNT_POINT="/mnt/infra"

if ! minikube status >/dev/null 2>&1; then
  echo "🚀 Starting Minikube..."
  minikube start --driver=docker --memory=4g --cpus=2 --mount --mount-string="$REPO_PATH:$MOUNT_POINT"
fi

if ! minikube ssh "ls $MOUNT_POINT" >/dev/null 2>&1; then
    echo "📁 Mounting local directory into Minikube..."
    minikube mount "$REPO_PATH:$MOUNT_POINT" &
    sleep 5
fi

minikube addons enable ingress

# --- 2. INSTALL ARGO CD ---
echo "⚙️ Installing Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side=true --force-conflicts

# --- 3. DÉCLARATION DU REPO LOCAL (MODE DIRECTORY PUR) ---
echo "📂 Registering local filesystem as a DIRECTORY repository..."
kubectl create secret generic local-repo-config \
  -n argocd \
  --from-literal=type=dir \
  --from-literal=url="/app/infra" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret local-repo-config -n argocd argocd.argoproj.io/secret-type=repository --overwrite

# --- 4. LE PATCH DU REPO-SERVER ---
echo "🛠️ Patching ArgoCD to use local filesystem..."
kubectl patch deployment argocd-repo-server -n argocd --type=json -p="[
  {
    \"op\": \"add\",
    \"path\": \"/spec/template/spec/volumes/-\",
    \"value\": {
      \"name\": \"local-infra\",
      \"hostPath\": { \"path\": \"$MOUNT_POINT\", \"type\": \"Directory\" }
    }
  },
  {
    \"op\": \"add\",
    \"path\": \"/spec/template/spec/containers/0/volumeMounts/-\",
    \"value\": {
      \"name\": \"local-infra\",
      \"mountPath\": \"/app/infra\"
    }
  }
]"

# --- 5. CONFIGURATION IMAGE UPDATER ---
echo "📦 Installing Image Updater..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/v0.12.2/manifests/install.yaml --server-side=true --force-conflicts

kubectl apply -f infra/argocd-config/image-updater-config.yaml

kubectl patch deployment argocd-image-updater -n argocd --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "registries-conf", "configMap": {"name": "argocd-image-updater-config"}}},
  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "registries-conf", "mountPath": "/app/config/registries.conf", "subPath": "registries.conf"}}
]'

# --- 6. PRÉPARATION NAMESPACE & BOOTSTRAP ---
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

echo "🏗️ Applying Local Root Application..."
kubectl apply -f infra/bootstrap/root-app.yaml

# Forcer le rafraîchissement immédiat
kubectl patch application root-app -n argocd --type merge -p '{"metadata": {"annotations": {"argocd.argoproj.io/refresh": "hard"}}}' 2>/dev/null || true

echo "-------------------------------------------------------"
echo "✅ Argo CD tourne en mode DIRECTORY PUR (Zéro GitHub)"
echo "-------------------------------------------------------"

PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
if [ -z "$PASS" ]; then
    PASS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}')
fi

echo "💡 Password : $PASS"
echo "💡 Forward  : kubectl port-forward svc/argocd-server -n argocd 8080:443"