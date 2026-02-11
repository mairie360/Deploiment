#!/bin/bash
set -e

echo "🏗️  Starting Server Bootstrapping (Declarative Mode)..."

# --- 1. INSTALLATION DES DÉPENDANCES ---
if ! command -v k3s &> /dev/null; then
  echo "📥 Installing K3s..."
  curl -sfL https://get.k3s.io | sh -
  sleep 5
  sudo chmod 644 /etc/rancher/k3s/k3s.yaml
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if ! command -v helm &> /dev/null; then
  echo "📥 Installing Helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- 2. CONFIGURATION DU STOCKAGE (Simple & Natif) ---
echo "🔧 Setting local-path as default storage..."
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' --type=merge

# --- 3. CHARGEMENT DU .ENV ---
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ Error: .env file missing at root."
  exit 1
fi

# --- 4. CONFIGURATION DU CLUSTER (Namespaces & Secrets) ---
echo "📂 Creating Namespaces and Secrets..."
for ns in dev staging prod; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret docker-registry ghcr-secret \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USERNAME" \
    --docker-password="$GHCR_TOKEN" \
    --docker-email="$GHCR_EMAIL" \
    -n $ns --dry-run=client -o yaml | kubectl apply -f -
done
kubectl create namespace portainer --dry-run=client -o yaml | kubectl apply -f -

# --- 5. NETTOYAGE DES PVC (Maintenant que le namespace existe) ---
echo "🧹 Cleaning up pending PVCs in 'dev'..."
kubectl get pvc -n dev 2>/dev/null | grep Pending | awk '{print $1}' | xargs -r kubectl delete pvc -n dev

# --- 6. INSTALLATION DES OUTILS (PORTAINER) ---
echo "📊 Deploying Portainer..."
helm repo add portainer https://portainer.github.io/k8s/ &> /dev/null
helm repo update &> /dev/null
helm upgrade --install portainer portainer/portainer --namespace portainer -f configs/portainer-values.yaml --skip-crds

# --- 7. DÉPLOIEMENT DE L'APPLICATION ---
echo "📦 Building App dependencies..."
helm dependency build ./mairie360

echo "🚀 Deploying 'dev' environment..."
helm upgrade --install mairie360 ./mairie360 \
  -f ./mairie360/values-dev.yaml \
  --set persistence.storageClass=local-path \
  --namespace dev \
  --atomic \
  --timeout 15m \
  --wait \
  --wait-for-jobs \
  --cleanup-on-fail

echo "✅ Full Bootstrap and Deployment successful!"

# --- RÉSUMÉ ---
SERVER_IP=$(curl -s ifconfig.me)
echo "--------------------------------------------------"
echo "🌐 Portainer UI : http://admin.mairie360.local"
echo "📍 Server IP    : $SERVER_IP"
echo "--------------------------------------------------"