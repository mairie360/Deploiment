#!/usr/bin/env bash
# =============================================================================
# Génère les SealedSecret d'une instance.
#
#   ./scripts/seal-secrets.sh <contexte-kube> <org> <env> [--rotate]
#
# Exemples :
#   ./scripts/seal-secrets.sh mairie360-dev  mairie360      dev
#   ./scripts/seal-secrets.sh paris-prod     client-paris   prod
#
# -> clusters/<org>/instances/<env>/secrets.yaml
#
# Le fichier produit est chiffré avec la clé du contrôleur sealed-secrets DE
# CETTE MACHINE. Il est commitable, y compris dans un dépôt public, et
# indéchiffrable ailleurs : c'est ce qui isole cryptographiquement les clients
# les uns des autres. Il faut donc le régénérer par machine.
#
# Prérequis : kubectl, kubeseal, openssl, un contexte kube valide, et le
# contrôleur sealed-secrets déployé (bootstrap/appsets/sealed-secrets-appset.yaml).
#
# Environment variables read by this script:
#   S3_ACCESS_KEY / S3_SECRET_KEY  Object Storage (Scaleway S3) key pair, stored
#                   under the same names in <env>-app-secrets (elearning-api
#                   stores course attachments there). When unset, the values
#                   already present on the cluster are kept; with neither, the
#                   keys are sealed empty and elearning-api will not start.
#   GHCR_USER / GHCR_TOKEN  optional, seal the ghcr-secret pull secret too.
#
# Par défaut, un secret déjà présent est CONSERVÉ (relancer ne casse pas une
# base existante). --rotate régénère tout.
# ATTENTION : faire tourner POSTGRES_PASSWORD ne change pas le mot de passe
# d'une base déjà initialisée — Postgres ne lit ces variables qu'au premier
# démarrage. Il faut un ALTER ROLE en parallèle.
# =============================================================================
set -euo pipefail

CTX="${1:?usage: $0 <contexte-kube> <org> <env> [--rotate]}"
ORG="${2:?}"
ENV="${3:?}"
ROTATE="${4:-}"

NS="mairie360-${ENV}"
RELEASE="${ENV}"               # instances-appset fixe releaseName = <env>
OUT="clusters/${ORG}/instances/${ENV}/secrets.yaml"
CONTROLLER_NS="kube-system"
CONTROLLER_NAME="sealed-secrets-controller"

for bin in kubectl kubeseal openssl; do
  command -v "$bin" >/dev/null || { echo "manquant : $bin"; exit 1; }
done
[ -d "clusters/${ORG}/instances/${ENV}" ] || { echo "Dossier inconnu : clusters/${ORG}/instances/${ENV}"; exit 1; }

echo "Contexte  : ${CTX}"
echo "Groupe    : ${ORG}"
echo "Namespace : ${NS}"
echo "Sortie    : ${OUT}"

prev() {
  kubectl --context "$CTX" -n "$NS" get secret "$1" \
    -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || true
}
gen() { openssl rand -base64 48 | tr -d '\n'; }

if [ "$ROTATE" = "--rotate" ]; then
  JWT=""; PGPASS=""; REDISPASS=""
else
  JWT="$(prev "${RELEASE}-app-secrets" JWT_SECRET)"
  PGPASS="$(prev "${RELEASE}-database-secret" POSTGRES_PASSWORD)"
  REDISPASS="$(prev "${RELEASE}-redis" redis-password)"
fi
[ -n "$JWT" ]       || { JWT="$(gen)";       echo "  JWT_SECRET       : généré"; }
[ -n "$PGPASS" ]    || { PGPASS="$(gen)";    echo "  POSTGRES_PASSWORD: généré"; }
[ -n "$REDISPASS" ] || { REDISPASS="$(gen)"; echo "  redis-password   : généré"; }

# The S3 key pair cannot be generated: it comes from S3_ACCESS_KEY /
# S3_SECRET_KEY, or is kept from the cluster. --rotate does not clear it (a new
# pair is issued from the Scaleway console, then passed through those vars).
S3AK="${S3_ACCESS_KEY:-}"
S3SK="${S3_SECRET_KEY:-}"
if [ -n "$S3AK" ] && [ -n "$S3SK" ]; then
  echo "  S3_ACCESS_KEY    : from S3_ACCESS_KEY"
  echo "  S3_SECRET_KEY    : from S3_SECRET_KEY"
elif [ -n "$S3AK" ] || [ -n "$S3SK" ]; then
  echo "S3_ACCESS_KEY and S3_SECRET_KEY must be set together" >&2
  exit 1
else
  S3AK="$(prev "${RELEASE}-app-secrets" S3_ACCESS_KEY)"
  S3SK="$(prev "${RELEASE}-app-secrets" S3_SECRET_KEY)"
  if [ -n "$S3AK" ] && [ -n "$S3SK" ]; then
    echo "  S3_ACCESS_KEY    : kept from cluster"
    echo "  S3_SECRET_KEY    : kept from cluster"
  else
    echo "  S3_*_KEY         : EMPTY (set S3_ACCESS_KEY and S3_SECRET_KEY) — elearning-api will not start" >&2
  fi
fi

GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"

seal() {
  kubeseal --context "$CTX" \
    --controller-namespace "$CONTROLLER_NS" \
    --controller-name "$CONTROLLER_NAME" \
    --format yaml
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

kubectl create secret generic "${RELEASE}-app-secrets" \
  --namespace "$NS" \
  --from-literal=JWT_SECRET="$JWT" \
  --from-literal=S3_ACCESS_KEY="$S3AK" \
  --from-literal=S3_SECRET_KEY="$S3SK" \
  --dry-run=client -o yaml | seal > "$TMP/app.yaml"

kubectl create secret generic "${RELEASE}-database-secret" \
  --namespace "$NS" \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD="$PGPASS" \
  --from-literal=POSTGRES_DB="mairie_db_${ENV}" \
  --dry-run=client -o yaml | seal > "$TMP/db.yaml"

kubectl create secret generic "${RELEASE}-redis" \
  --namespace "$NS" --from-literal=redis-password="$REDISPASS" \
  --dry-run=client -o yaml | seal > "$TMP/redis.yaml"

if [ -n "$GHCR_TOKEN" ]; then
  kubectl create secret docker-registry ghcr-secret \
    --namespace "$NS" --docker-server=ghcr.io \
    --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | seal > "$TMP/ghcr.yaml"
fi

mkdir -p "$(dirname "$OUT")"
{
  echo "# ==========================================================================="
  echo "# SealedSecret de ${ORG} / ${ENV}."
  echo "#"
  echo "# GÉNÉRÉ PAR scripts/seal-secrets.sh — ne pas éditer à la main."
  echo "# Chiffré avec la clé du contrôleur sealed-secrets de CETTE machine :"
  echo "# commitable tel quel, indéchiffrable ailleurs."
  echo "#"
  echo "# Régénérer (conserve les valeurs existantes) :"
  echo "#   ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV}"
  echo "# Faire tourner tous les secrets :"
  echo "#   ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV} --rotate"
  echo "# Change the Object Storage key pair (S3_ACCESS_KEY / S3_SECRET_KEY of elearning-api):"
  echo "#   S3_ACCESS_KEY=SCW... S3_SECRET_KEY=... ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV}"
  echo "# ==========================================================================="
  echo "extraObjects:"
  for f in "$TMP"/*.yaml; do
    echo "  - |"
    sed 's/^/    /' "$f"
  done
} > "$OUT"

echo
echo "Écrit : $OUT"
echo "Sauvegardez la clé de scellement de cette machine (irrécupérable si perdue) :"
echo "  kubectl --context $CTX -n $CONTROLLER_NS get secret \\"
echo "    -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealing-key-${CTX}.yaml"
