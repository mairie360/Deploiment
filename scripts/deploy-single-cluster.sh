#!/bin/bash
set -e

# --- ÉTAPE 1 : PRÉPARATION DU CLUSTER ET DES OUTILS ---

# Vérifie si Minikube est lancé, sinon le démarre
if ! minikube status >/dev/null 2>&1; then
  echo "Démarrage de Minikube..."
  minikube start --driver=docker --memory=4g --cpus=2
fi

# # Nom du chart (commenté car lié au déploiement d'app)
# CHART_DIR="./mairie360"
# CHART_NAME="mairie360"

# # Charger les variables d'environnement depuis .env s'il existe (commenté car lié au déploiement d'app)
# if [ -f ".env" ]; then
#   echo "Chargement des variables d'environnement depuis .env..."
#   export $(grep -v '^#' .env | xargs)
# else
#   echo "⚠️  Aucun fichier .env trouvé. Assure-toi que les variables GHCR_* sont définies."
# fi

# # Vérification des variables nécessaires (commenté car lié au déploiement d'app)
# if [ -z "$GHCR_USERNAME" ] || [ -z "$GHCR_TOKEN" ] || [ -z "$GHCR_EMAIL" ]; then
#   echo "❌ Erreur : il manque au moins une des variables suivantes : GHCR_USERNAME, GHCR_TOKEN, GHCR_EMAIL"
#   exit 1
# fi


# --- ÉTAPE 2 : INSTALLATION ET ATTENTE DE VAULT ---

# Installer Vault via Helm
helm repo add hashicorp https://helm.releases.hashicorp.com || true
helm repo update
helm install vault hashicorp/vault -f vault-values.yaml || helm upgrade vault hashicorp/vault -f vault-values.yaml

# Attendre que le pod Vault soit ready
echo "⏳ Attente que le pod Vault soit fully ready..."
kubectl wait --for=condition=ready pod/vault-0 --timeout=5m

echo "⏳ Attente que Vault soit fully ready..."
until kubectl exec vault-0 -- vault status &>/dev/null; do
    echo "Vault pas encore prêt…"
    sleep 2
done

echo "✅ Vault est prêt !"


# --- ÉTAPE 3 : CONFIGURATION VAULT (Policies, Rôles, Secrets) ---

# Activer l'authentification Kubernetes dans Vault
echo "🔑 Activation de l'auth Kubernetes dans Vault..."
kubectl exec vault-0 -- vault auth enable kubernetes || true

# Créer le dossier de policies si nécessaire
POLICY_DIR="deployments/vault-config/policies"
mkdir -p "$POLICY_DIR"

# Créer une policy par défaut si aucun fichier .hcl n'existe
if [ -z "$(ls -A $POLICY_DIR/*.hcl 2>/dev/null)" ]; then
  echo "Création de la policy par défaut 'database.hcl'"
  cat > "$POLICY_DIR/database.hcl" <<EOL
path "secret/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOL
fi

# Appliquer les policies
for policy_file in deployments/vault-config/policies/*.hcl; do
  policy_name=$(basename "$policy_file" .hcl)
  echo "📜 Application de la policy : $policy_name"

  # Copier le fichier dans le pod
  kubectl cp "$policy_file" vault-0:/tmp/"$policy_name".hcl

  # Appliquer la policy depuis le pod
  kubectl exec vault-0 -- vault policy write "$policy_name" /tmp/"$policy_name".hcl
done


# Appliquer les rôles et secrets pour chaque environnement
for env in dev staging prod; do
  echo "🔑 Configuration de l'environnement : $env"

  # Créer le rôle Kubernetes
  kubectl exec vault-0 -- vault write auth/kubernetes/role/database-"$env" \
    bound_service_account_names="database" \
    bound_service_account_namespaces="$env" \
    policies="database-$env,shared-db-coreAPI-$env" \
    ttl="24h" || true

  # Créer le dossier secrets si nécessaire
  secrets_dir="deployments/vault-config/secrets/$env"
  mkdir -p "$secrets_dir"

# Charger les secrets si des fichiers existent
  if compgen -G "$secrets_dir/*.yaml" > /dev/null; then
    for secret_file in "$secrets_dir"/*.yaml; do
      secret_name=$(basename "$secret_file" .yaml)
      echo "💾 Chargement du secret : $secret_name"
      
      # NOTE IMPORTANTE : Assurez-vous d'avoir corrigé cette section pour qu'elle fonctionne
      # La méthode de copie + lecture locale dans le pod est la plus fiable
      # Si vous rencontrez encore une erreur ici, la cause est le format YAML vs JSON (voir ma réponse précédente).
      kubectl cp "$secret_file" vault-0:/tmp/secret-temp.yaml
      kubectl exec vault-0 -- vault kv put secret/mairie360/"$secret_name"/"$env" @/tmp/secret-temp.yaml

    done
  else
    echo "⚠️ Aucun secret trouvé pour $env, dossier vide."
  fi
done
echo "✅ Vault configuré pour dev, staging et prod !"


# --- ÉTAPE 4 : INSTALLATION DES OUTILS K8S POUR LA CONNEXION À VAULT ---

echo "⚙️ Installation du Vault CSI Driver pour la connexion K8s..."
# Ajout du repo Helm pour le CSI Driver
helm repo add hashicorp-csi https://helm.releases.hashicorp.com || true
helm repo update

# Installation du Vault Secrets Operator (inclut le CSI Driver)
helm install vault-secrets-operator hashicorp-csi/vault-secrets-operator --version 0.5.0 || \
helm upgrade vault-secrets-operator hashicorp-csi/vault-secrets-operator --version 0.5.0

echo "✅ Vault CSI Driver installé et prêt à l'emploi."


# --- ÉTAPE 5 : CONFIGURATION DES SECRETS EN KUBERNETES ---

# Cette étape est celle qui fait le "branchement" final.
# Elle applique les fichiers SecretProviderClass (deployments/k8s/vault/*.yaml).
# Le code pour cette étape sera inclus dans la prochaine étape de "branchement K8s".


# --- CODE COMMENTÉ, À ACTIVER DANS UNE ÉTAPE ULTERIEURE ---

# GHCR_SERVER="ghcr.io"
# GHCR_SECRET_NAME="ghcr-secret"


# # Création des namespaces et secrets (lié au déploiement d'app)
# for ns in dev staging prod; do
# #   if ! kubectl get namespace $ns >/dev/null 2>&1; then
# #     echo "Création du namespace $ns"
# #     kubectl create namespace $ns
# #   else
# #     echo "Namespace $ns existe déjà"
# #   fi

# #   # Création du secret si non existant (lié au déploiement d'app)
# #   if ! kubectl get secret $GHCR_SECRET_NAME -n $ns >/dev/null 2>&1; then
# #     echo "Création du secret $GHCR_SECRET_NAME dans le namespace $ns..."
# #     kubectl create secret docker-registry $GHCR_SECRET_NAME \
# #       --docker-server=$GHCR_SERVER \
# #       --docker-username=$GHCR_USERNAME \
# #       --docker-password=$GHCR_TOKEN \
# #       --docker-email=$GHCR_EMAIL \
# #       -n $ns
# #   else
# #     echo "Secret $GHCR_SECRET_NAME déjà présent dans le namespace $ns"
# #   fi
# done

# # Déploiement dans chaque namespace avec son fichier values (lié au déploiement d'app)
# # echo "Déploiement Dev..."
# # helm upgrade --install $CHART_NAME $CHART_DIR -f $CHART_DIR/values-dev.yaml -n dev

# # # echo "Déploiement Staging..."
# # # helm upgrade --install $CHART_NAME $CHART_DIR -f $CHART_DIR/values-staging.yaml -n staging

# # # echo "Déploiement Prod..."
# # # helm upgrade --install $CHART_NAME $CHART_DIR -f $CHART_DIR/values-prod.yaml -n prod

# # echo "✅ Tous les environnements déployés dans un seul cluster"