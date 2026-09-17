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
# Par défaut, un secret déjà présent est CONSERVÉ (relancer ne casse pas une
# base existante). --rotate régénère tout.
# ATTENTION : faire tourner POSTGRES_PASSWORD ou un <ROLE>_PASSWORD ne change
# pas le mot de passe d'un rôle déjà créé — Postgres ne lit POSTGRES_PASSWORD
# qu'au tout premier démarrage, et les <ROLE>_PASSWORD ne sont lus par le job
# Liquibase (-D<role>_password) que lors du changeset CREATE ROLE, qui ne
# rejoue pas. Il faut un ALTER ROLE en parallèle.
# À l'inverse, Redis régénère /acl/users.acl à partir des variables d'env à
# CHAQUE démarrage (voir charts/.../redis/templates/configmap.yaml) : un
# simple redémarrage du pod suffit à faire prendre une rotation des mots de
# passe ACL, pas besoin d'équivalent à ALTER ROLE.
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

# Rôles ACL Redis : un compte par API et par BFF déclarée dans
# global.apis.instances / global.bffs.instances (charts/mairie360-stack/values.yaml).
# À TENIR SYNCHRONISÉ avec ce fichier si la liste des instances change.
REDIS_ROLES="core-api project-api calendar-api message-api email-api files-api elearning-api user-bff project-bff calendar-bff message-bff email-bff files-bff elearning-bff"

# Postgres roles (MAIR-114): one per API that owns a schema, matching
# global.database.roles in charts/mairie360-stack/values.yaml. Deliberately
# a SHORTER list than REDIS_ROLES: email-api/files-api have no repo yet, so
# no role is created for them by Devops/Database's Liquibase changelog.
# Keep in sync with that values.yaml key.
DB_ROLES="core-api project-api calendar-api message-api elearning-api"

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
  JWT=""; PGPASS=""; ADMINPASS=""
else
  JWT="$(prev "${RELEASE}-app-secrets" JWT_SECRET)"
  PGPASS="$(prev "${RELEASE}-database-secret" POSTGRES_PASSWORD)"
  ADMINPASS="$(prev "${RELEASE}-redis" redis-password)"
fi
[ -n "$JWT" ]        || { JWT="$(gen)";        echo "  JWT_SECRET             : généré"; }
[ -n "$PGPASS" ]     || { PGPASS="$(gen)";     echo "  POSTGRES_PASSWORD      : généré"; }
[ -n "$ADMINPASS" ]  || { ADMINPASS="$(gen)";  echo "  redis-password (admin) : généré"; }

redis_args=(--from-literal="redis-password=${ADMINPASS}")
for role in $REDIS_ROLES; do
  key="${role}-password"
  if [ "$ROTATE" = "--rotate" ]; then
    val=""
  else
    val="$(prev "${RELEASE}-redis" "$key")"
  fi
  [ -n "$val" ] || { val="$(gen)"; echo "  ${key} : généré"; }
  redis_args+=(--from-literal="${key}=${val}")
done

db_args=(
  --from-literal=POSTGRES_USER=postgres
  --from-literal=POSTGRES_PASSWORD="${PGPASS}"
  --from-literal=POSTGRES_DB="mairie_db_${ENV}"
)
for role in $DB_ROLES; do
  key="$(printf '%s' "$role" | tr 'a-z-' 'A-Z_')_PASSWORD"
  if [ "$ROTATE" = "--rotate" ]; then
    val=""
  else
    val="$(prev "${RELEASE}-database-secret" "$key")"
  fi
  [ -n "$val" ] || { val="$(gen)"; echo "  ${key} : généré"; }
  db_args+=(--from-literal="${key}=${val}")
done

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
  --namespace "$NS" --from-literal=JWT_SECRET="$JWT" \
  --dry-run=client -o yaml | seal > "$TMP/app.yaml"

kubectl create secret generic "${RELEASE}-database-secret" \
  --namespace "$NS" "${db_args[@]}" \
  --dry-run=client -o yaml | seal > "$TMP/db.yaml"

kubectl create secret generic "${RELEASE}-redis" \
  --namespace "$NS" "${redis_args[@]}" \
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
