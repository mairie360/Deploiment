#!/bin/bash
set -e

echo "🏗️  Starting Server Bootstrapping (Declarative Mode)..."

# --- 1. INSTALLATION DES DÉPENDANCES (IDEMPOTENT) ---
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

# --- 2. CHARGEMENT DU .ENV ---
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ Error: .env file missing at root."
  exit 1
fi

# --- 3. CONFIGURATION DU CLUSTER (Namespaces & Secrets) ---
# On boucle sur les environnements applicatifs uniquement pour les secrets GHCR
for ns in dev staging prod; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret docker-registry ghcr-secret \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USERNAME" \
    --docker-password="$GHCR_TOKEN" \
    --docker-email="$GHCR_EMAIL" \
    -n $ns --dry-run=client -o yaml | kubectl apply -f -
done

# Namespace pour les outils d'admin
kubectl create namespace portainer --dry-run=client -o yaml | kubectl apply -f -

# --- 4. INSTALLATION DES OUTILS (PORTAINER) ---
echo "📊 Deploying Portainer via config file..."
helm repo add portainer https://portainer.github.io/k8s/
helm repo update

# On utilise le fichier de config externe
helm upgrade --install portainer portainer/portainer \
  --namespace portainer \
  -f configs/portainer-values.yaml

# --- 5. DÉPLOIEMENT DE L'APPLICATION ---
echo "📦 Building App dependencies..."
helm dependency build ./mairie360

echo "🚀 Deploying 'dev' environment..."
helm upgrade --install mairie360 ./mairie360 \
  -f ./mairie360/values-dev.yaml \
  --namespace dev \
  --wait

echo "✅ Full Bootstrap and Deployment successful!"

# --- RÉSUMÉ DES ACCÈS ---
SERVER_IP=$(curl -s ifconfig.me)

echo "--------------------------------------------------"
echo "🌐 ACCESS INFO"
echo "Portainer UI : http://admin.mairie360.local"
echo "Server IP    : $SERVER_IP"
echo ""
echo "💡 Rappel : Ajoute cette ligne à ton /etc/hosts local :"
echo "$SERVER_IP  admin.mairie360.local"
echo "--------------------------------------------------"
