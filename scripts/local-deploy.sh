#!/bin/bash
set -e

# --- 1. INFRASTRUCTURE CHECK ---
if ! minikube status >/dev/null 2>&1; then
  echo "🚀 Starting Minikube..."
  minikube start --driver=docker --memory=4g --cpus=2
fi

# Enable Ingress for local access (essential for later)
minikube addons enable ingress

# --- 2. ENVIRONMENT & SECRETS ---
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Ensure GHCR credentials are present
if [ -z "$GHCR_USERNAME" ] || [ -z "$GHCR_TOKEN" ]; then
  echo "❌ Error: GHCR_USERNAME or GHCR_TOKEN not set in .env"
  exit 1
fi

# --- 3. PREPARE NAMESPACES & AUTH ---
# In solo cluster, we mostly use 'dev'. CI/CD will handle 'staging/prod' in real clusters.
for ns in dev staging prod; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -

  # Update/Create the image pull secret
  kubectl create secret docker-registry ghcr-secret \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USERNAME" \
    --docker-password="$GHCR_TOKEN" \
    --docker-email="$GHCR_EMAIL" \
    -n $ns --dry-run=client -o yaml | kubectl apply -f -
done

# --- 4. INITIAL DEPLOYMENT ---
echo "📦 Building Helm dependencies..."
helm dependency build ./mairie360

echo "🚀 Bootstrapping Dev environment..."
# The CI/CD will later call 'helm upgrade' with specific --set image.tag=v1.x.x
# Here we just launch the base version defined in values.yaml
helm upgrade --install mairie360 ./mairie360 \
  -f ./mairie360/values-dev.yaml \
  --namespace dev \
  --wait

echo "✅ Cluster is up and Base DB is deploying."