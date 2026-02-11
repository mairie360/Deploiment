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

# --- 2. CONFIGURATION DU STOCKAGE (K3S Fix) ---
echo "🔧 Configuring Storage Classes..."
# On définit local-path comme défaut
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' --type=merge

# On crée l'alias 'standard' pour correspondre aux attentes de tes Charts Helm
if ! kubectl get storageclass standard &> /dev/null; then
  echo "📦 Creating 'standard' storageclass alias..."
  kubectl get storageclass local-path -o json | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp) | .metadata.name = "standard"' | kubectl apply -f -
fi

# --- 3. CHARGEMENT DU .ENV ---
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ Error: .env file missing at root."
  exit 1
fi

# --- 4. CONFIGURATION DU CLUSTER (Namespaces & Secrets) ---
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

# --- 5. NETTOYAGE DES PVC EN ATTENTE (Optionnel mais recommandé en Dev) ---
# Si des PVC sont bloqués en Pending sur l'ancienne config, on les purge pour repartir propre
echo "🧹 Checking for pending PVCs..."
kubectl get pvc -n dev | grep Pending | awk '{print $1}' | xargs -r kubectl delete pvc -n dev

# --- 6. INSTALLATION DES OUTILS (PORTAINER) ---
echo "📊 Deploying Portainer via config file..."
helm repo add portainer https://portainer.github.io/k8s/
helm repo update

helm upgrade --install portainer portainer/portainer \
  --namespace portainer \
  -f configs/portainer-values.yaml

# --- 7. DÉPLOIEMENT DE L'APPLICATION ---
echo "📦 Building App dependencies..."
helm dependency build ./mairie360

echo "🚀 Deploying 'dev' environment..."
helm upgrade --install mairie360 ./mairie360 \
  -f ./mairie360/values-dev.yaml \
  --namespace dev \
  --atomic \
  --timeout 15m \
  --wait-for-jobs \
  --cleanup-on-fail

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
