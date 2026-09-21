#!/usr/bin/env bash
# =============================================================================
# Génère les SealedSecret d'une instance.
#
#   ./scripts/seal-secrets.sh <contexte-kube> <org> <env> [--rotate]
#
# Normally run by ansible (playbooks/secrets.yml, role k8s_instance_secrets),
# on the group's Argo CD machine: it is the only one that reaches the instance
# API server, through the WireGuard tunnel. The role prompts for the external
# keys below, then copies secrets.yaml back to the workstation to be committed.
# By hand, from /opt/Deploiment on that machine (the kubeconfig written by
# role k8s_instance_link names its context after the environment):
#
#   KUBECONFIG=/root/.kube/instance-dev.yaml ./scripts/seal-secrets.sh dev mairie360 dev
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
#   RESEND_API_KEY  Resend API key, stored as SMTP_PASSWORD in <env>-app-secrets
#                   (core-api sends its e-mails through smtp.resend.com). When
#                   unset, the value already present on the cluster is kept;
#                   with neither, the key is sealed empty and e-mails will fail.
#   S3_ACCESS_KEY / S3_SECRET_KEY  Object Storage (Scaleway S3) key pair, stored
#                   under the same names in <env>-app-secrets (elearning-api
#                   stores course attachments there). When unset, the values
#                   already present on the cluster are kept; with neither, the
#                   keys are sealed empty and elearning-api will not start.
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  backup bucket key pair (MAIR-119),
#                   see below. Without them <env>-backup-secret is not sealed.
#   GHCR_USER / GHCR_TOKEN  optional, seal the ghcr-secret pull secret too.
#
# Par défaut, un secret déjà présent est CONSERVÉ (relancer ne casse pas une
# base existante). --rotate régénère tout.
#
# MAIR-119: if backup (charts/backup) is enabled for this instance, export
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY before calling this script —
# they cannot be generated, they are credentials for the external S3 bucket.
# RESTIC_PASSWORD is generated like JWT_SECRET / POSTGRES_PASSWORD; LOSING IT
# MAKES EVERY EXISTING BACKUP UNREADABLE, keep it outside the cluster too,
# like the sealing key.
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
REDIS_ROLES="core-api project-api calendar-api message-api elearning-api user-bff project-bff calendar-bff message-bff elearning-bff dashboard-bff settings-bff"

# Postgres roles (MAIR-114): one per API that owns a schema, matching
# global.database.roles in charts/mairie360-stack/values.yaml. Deliberately
# a SHORTER list than REDIS_ROLES: dashboard-bff/settings-bff have no
# database of their own, so no role is created for them by
# Devops/Database's Liquibase changelog. Keep in sync with that values.yaml
# key.
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
  JWT=""; PGPASS=""; ADMINPASS=""; RESTICPASS=""
else
  JWT="$(prev "${RELEASE}-app-secrets" JWT_SECRET)"
  PGPASS="$(prev "${RELEASE}-database-secret" POSTGRES_PASSWORD)"
  ADMINPASS="$(prev "${RELEASE}-redis" redis-password)"
  RESTICPASS="$(prev "${RELEASE}-backup-secret" RESTIC_PASSWORD)"
fi
[ -n "$JWT" ]        || { JWT="$(gen)";        echo "  JWT_SECRET             : généré"; }
[ -n "$PGPASS" ]     || { PGPASS="$(gen)";     echo "  POSTGRES_PASSWORD      : généré"; }
[ -n "$ADMINPASS" ]  || { ADMINPASS="$(gen)";  echo "  redis-password (admin) : généré"; }
[ -n "$RESTICPASS" ] || { RESTICPASS="$(gen)"; echo "  RESTIC_PASSWORD        : generated"; }

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

# The Resend API key cannot be generated: it comes from RESEND_API_KEY, or is
# kept from the cluster. --rotate does not clear it (a new key is issued from
# the Resend dashboard, then passed through RESEND_API_KEY).
SMTPPASS="${RESEND_API_KEY:-}"
if [ -n "$SMTPPASS" ]; then
  echo "  SMTP_PASSWORD    : from RESEND_API_KEY"
else
  SMTPPASS="$(prev "${RELEASE}-app-secrets" SMTP_PASSWORD)"
  if [ -n "$SMTPPASS" ]; then
    echo "  SMTP_PASSWORD    : kept from cluster"
  else
    echo "  SMTP_PASSWORD    : EMPTY (set RESEND_API_KEY) — core-api cannot send e-mails" >&2
  fi
fi

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

# MAIR-119: unlike the other secrets, these are credentials for an external
# S3 bucket and can't be generated — only sealed when supplied. Skip the
# backup-secret entirely if backup isn't provisioned for this instance yet.
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

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
  --from-literal=SMTP_PASSWORD="$SMTPPASS" \
  --from-literal=S3_ACCESS_KEY="$S3AK" \
  --from-literal=S3_SECRET_KEY="$S3SK" \
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

if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
  kubectl create secret generic "${RELEASE}-backup-secret" \
    --namespace "$NS" \
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --from-literal=RESTIC_PASSWORD="$RESTICPASS" \
    --dry-run=client -o yaml | seal > "$TMP/backup.yaml"
else
  echo "  backup-secret : skipped (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY not provided)"
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
  echo "# Change the Resend API key (SMTP_PASSWORD of core-api):"
  echo "#   RESEND_API_KEY=re_xxx ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV}"
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
