#!/usr/bin/env bash
# =============================================================================
# Génère les SealedSecret d'une instance.
#
#   ./scripts/seal-secrets.sh <contexte-kube> <org> <env> [--rotate | --rotate-roles]
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
#   BACKUP_SCW_SECRET_KEY  Scaleway Key Manager API key of the sealed backups
#                   (MAIR-500, backup.sealing): create keys, generate and decrypt
#                   data keys. COMPLIANCE_SCW_SECRET_KEY: the one compliance-api
#                   uses to destroy a user's key at erasure. Kept from the
#                   cluster when unset.
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  backup bucket key pair (MAIR-119),
#                   see below. When unset, the pair already on the cluster is
#                   kept; with neither, <env>-backup-secret is not sealed.
#   RESTIC_PASSWORD / ADMIN_PASSWORD  normally generated here, but the ansible
#                   role resolves them itself and passes them in, so the value
#                   sealed is exactly the one it backs up on the workstation
#                   (~/.mairie360/restic-<org>-<env>.txt, admin-<org>-<env>.txt).
#                   When set, used as-is, even with --rotate; when unset,
#                   kept from the cluster, else generated.
#                   ADMIN_PASSWORD is the PLAINTEXT first password of the admin
#                   account: what is sealed is its argon2id hash (MAIR-414,
#                   Database's create_admin.sql and chk_users_password_hashed
#                   only accept a hash). An ADMIN_PASSWORD that already is an
#                   `$argon2id$` hash is sealed as-is. Hashing needs OpenSSL
#                   >= 3.2 (`openssl kdf ARGON2ID`) or the `argon2` CLI.
#   ADMIN_PASSWORD_FILE  where a password generated here is written (mode 600)
#                   for the operator, default ~/.mairie360/admin-<org>-<env>.txt.
#                   The cluster only ever gets the hash.
#   ADMIN_EMAIL     e-mail of the town hall's administrator account (MAIR-170),
#                   stored as-is in <env>-database-secret. When unset, the
#                   value already present on the cluster is kept; with
#                   neither, the script fails (MAIR-414): the Liquibase Job
#                   refuses to run without it rather than seed the public
#                   template admin account.
#   BFF_USER_CLIENT_SECRET  Keycloak client secret of bff-user (MAIR-139), only
#                   to re-seal one regenerated in the admin console; otherwise
#                   the value on the cluster is kept, or generated once.
#   COCKPIT_TOKEN   Scaleway Cockpit token (push metrics + push traces scopes),
#                   stored in <env>-cockpit-secret for the OpenTelemetry
#                   Collector (MAIR-131, charts/observability). When unset, the
#                   value already on the cluster is kept; with neither, that
#                   Secret is not sealed (only needed with
#                   global.observability.enabled).
#   COMPLIANCE_KEYCLOAK_CLIENT_SECRET / COMPLIANCE_RESEND_API_KEY /
#   COMPLIANCE_S3_ACCESS_KEY_ID / COMPLIANCE_S3_SECRET_ACCESS_KEY  erasure
#                   credentials of the compliance service (MAIR-498), stored in
#                   <env>-compliance-secret, mounted in compliance-api only.
#                   Each one unset keeps the value on the cluster; with none at
#                   all, that Secret is not sealed (only needed with
#                   global.compliance.enabled, every key is optional).
#   GHCR_USER / GHCR_TOKEN  optional, seal the ghcr-secret pull secret too.
#
# Par défaut, un secret déjà présent est CONSERVÉ (relancer ne casse pas une
# base existante). --rotate régénère tout, SAUF ADMIN_PASSWORD (MAIR-170):
# the Liquibase Job only sets it while the admin account still carries its
# changelog template credentials, so once the town hall administrator has
# logged in and changed it, rotating the sealed value here would just make
# it wrong — the Job would leave the live account untouched either way.
# ADMIN_EMAIL is likewise never rotated, so both stay in lockstep with
# whatever the admin last set. Same for <env>-keycloak-secret (MAIR-139):
# Keycloak reads the bootstrap admin password on the first start of an empty
# database only, its Postgres reads KEYCLOAK_DB_PASSWORD on first init only,
# and the realm (hence bff-user's client secret) is imported once — rotating
# the sealed values would change nothing live and only desynchronise them.
# Rotate those in Keycloak itself (admin console / ALTER ROLE), then re-seal
# with BFF_USER_CLIENT_SECRET set. --rotate-roles ne régénère que les
# <ROLE>_PASSWORD Postgres des APIs : the Liquibase Job (an Argo CD Sync
# hook, rerun on every sync) runs `ALTER ROLE ... PASSWORD` with the new
# values, so after pushing secrets.yaml only the API pods need a restart
# (`kubectl rollout restart deploy -l app.kubernetes.io/component=api`).
#
# Generated values are hex: the APIs build `postgres://user:password@host`
# without percent-encoding the password, so a base64 value containing `/`
# breaks the URL ("invalid port number", "Name or service not known").
#
# MAIR-119: if backup (charts/backup) is enabled for this instance, export
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY before calling this script —
# they cannot be generated, they are credentials for the external S3 bucket.
# RESTIC_PASSWORD is generated like JWT_SECRET / POSTGRES_PASSWORD; LOSING IT
# MAKES EVERY EXISTING BACKUP UNREADABLE, keep it outside the cluster too,
# like the sealing key.
# WARNING: rotating POSTGRES_PASSWORD does not change the live superuser
# (Postgres reads it on first init only): run `ALTER ROLE postgres PASSWORD`
# by hand. The API <ROLE>_PASSWORD are altered by the Liquibase Job on the
# next sync (see --rotate-roles above), and Redis rewrites /acl/users.acl from
# its env vars at every start: a pod restart applies a rotated ACL password.
# =============================================================================
set -euo pipefail

CTX="${1:?usage: $0 <contexte-kube> <org> <env> [--rotate | --rotate-roles]}"
ORG="${2:?}"
ENV="${3:?}"
ROTATE="${4:-}"

NS="mairie360-${ENV}"
RELEASE="${ENV}"               # instances-appset fixe releaseName = <env>
OUT="clusters/${ORG}/instances/${ENV}/secrets.yaml"
CONTROLLER_NS="kube-system"
CONTROLLER_NAME="sealed-secrets-controller"

# Redis ACL roles: one account per API declared in global.apis.instances
# (charts/mairie360-stack/values.yaml). The BFFs have none since MAIR-414.
# KEEP IN SYNC with that file if the list of APIs changes. compliance-api
# (MAIR-498) only gets its account with global.compliance.enabled, but its
# password is sealed everywhere so the switch needs no re-seal.
REDIS_ROLES="core-api project-api calendar-api message-api elearning-api compliance-api"

# Postgres roles (MAIR-114): one per API that owns a schema, matching
# global.database.roles in charts/mairie360-stack/values.yaml. Deliberately
# a SHORTER list than REDIS_ROLES: dashboard-bff/settings-bff have no
# database of their own, so no role is created for them by
# Devops/Database's Liquibase changelog. Keep in sync with that values.yaml
# key. compliance-api (MAIR-498): same as REDIS_ROLES, sealed ahead of
# global.compliance.enabled.
DB_ROLES="core-api project-api calendar-api message-api elearning-api compliance-api"

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
gen() { openssl rand -hex 32; }

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
if [ -n "${RESTIC_PASSWORD:-}" ]; then
  RESTICPASS="$RESTIC_PASSWORD"; echo "  RESTIC_PASSWORD        : from RESTIC_PASSWORD"
fi
[ -n "$RESTICPASS" ] || { RESTICPASS="$(gen)"; echo "  RESTIC_PASSWORD        : generated"; }

# MAIR-170: the town hall admin account's e-mail/password. Unlike the block
# above, ALWAYS kept from the cluster regardless of --rotate/--rotate-roles
# — see the --rotate comment near the top of this file.
APPADMINEMAIL="${ADMIN_EMAIL:-}"
if [ -n "$APPADMINEMAIL" ]; then
  echo "  ADMIN_EMAIL      : from ADMIN_EMAIL"
else
  APPADMINEMAIL="$(prev "${RELEASE}-database-secret" ADMIN_EMAIL)"
  if [ -n "$APPADMINEMAIL" ]; then
    echo "  ADMIN_EMAIL      : kept from cluster"
  else
    echo "ADMIN_EMAIL is empty and not sealed on the cluster: set ADMIN_EMAIL (MAIR-414)" >&2
    exit 1
  fi
fi

# MAIR-414: the sealed ADMIN_PASSWORD is an argon2id PHC hash, the plaintext
# never reaches the cluster. Same parameters as the Database template hash
# (OWASP minimum: m=19456 KiB, t=2, p=1); Core API reads them from the hash.
is_argon2id() { case "$1" in '$argon2id$'*) return 0 ;; *) return 1 ;; esac; }
argon2id_hash() {
  local pw="$1" salt raw
  # 16 random hex characters used as the (printable) salt bytes, so the same
  # string feeds both tools without handling binary data in the shell.
  salt="$(openssl rand -hex 8)"
  if openssl list -kdf-algorithms 2>/dev/null | grep -qi argon2id; then
    raw="$(openssl kdf -keylen 32 -binary -kdfopt pass:"$pw" -kdfopt salt:"$salt" \
      -kdfopt iter:2 -kdfopt memcost:19456 -kdfopt lanes:1 ARGON2ID | base64 | tr -d '=\n')"
    printf '$argon2id$v=19$m=19456,t=2,p=1$%s$%s' "$(printf '%s' "$salt" | base64 | tr -d '=\n')" "$raw"
  elif command -v argon2 >/dev/null; then
    printf '%s' "$pw" | argon2 "$salt" -id -t 2 -k 19456 -p 1 -l 32 -e
  else
    echo "cannot hash ADMIN_PASSWORD: needs OpenSSL >= 3.2 or the argon2 CLI (apt install argon2)" >&2
    return 1
  fi
}
# A password this script came up with (generated, or the plaintext sealed
# before MAIR-414) is handed to the operator in a 600 file, never printed.
save_admin_password() {
  local file="${ADMIN_PASSWORD_FILE:-$HOME/.mairie360/admin-${ORG}-${ENV}.txt}"
  mkdir -p "$(dirname "$file")"
  [ ! -e "$file" ] || mv "$file" "${file}.$(date +%Y%m%d%H%M%S)"
  (umask 077; printf '%s\n' "$1" > "$file")
  echo "  ADMIN_PASSWORD   : plaintext written to $file (store it in the team vault)"
}
APPADMINPWD="${ADMIN_PASSWORD:-}"
if [ -n "$APPADMINPWD" ]; then
  echo "  ADMIN_PASSWORD   : from ADMIN_PASSWORD"
else
  APPADMINPWD="$(prev "${RELEASE}-database-secret" ADMIN_PASSWORD)"
  if is_argon2id "$APPADMINPWD"; then
    echo "  ADMIN_PASSWORD   : kept from cluster"
  elif [ -n "$APPADMINPWD" ]; then
    # Sealed in plaintext before MAIR-414: hash that same value.
    echo "  ADMIN_PASSWORD   : plaintext found on the cluster, hashed"
    save_admin_password "$APPADMINPWD"
  else
    APPADMINPWD="$(gen)"
    echo "  ADMIN_PASSWORD   : generated"
    save_admin_password "$APPADMINPWD"
  fi
fi
is_argon2id "$APPADMINPWD" || APPADMINPWD="$(argon2id_hash "$APPADMINPWD")"

# MAIR-139: Keycloak bootstrap admin, its Postgres role and bff-user's client
# secret. Never rotated by --rotate (see the comment near the top): kept from
# the cluster, generated once when absent.
KCADMINPWD="$(prev "${RELEASE}-keycloak-secret" KEYCLOAK_ADMIN_PASSWORD)"
[ -n "$KCADMINPWD" ] || { KCADMINPWD="$(gen)"; echo "  KEYCLOAK_ADMIN_PASSWORD : generated"; }
KCDBPWD="$(prev "${RELEASE}-keycloak-secret" KEYCLOAK_DB_PASSWORD)"
[ -n "$KCDBPWD" ] || { KCDBPWD="$(gen)"; echo "  KEYCLOAK_DB_PASSWORD    : generated"; }
KCBFFSECRET="${BFF_USER_CLIENT_SECRET:-}"
if [ -n "$KCBFFSECRET" ]; then
  echo "  BFF_USER_CLIENT_SECRET  : from BFF_USER_CLIENT_SECRET"
else
  KCBFFSECRET="$(prev "${RELEASE}-keycloak-secret" BFF_USER_CLIENT_SECRET)"
  [ -n "$KCBFFSECRET" ] || { KCBFFSECRET="$(gen)"; echo "  BFF_USER_CLIENT_SECRET  : generated"; }
fi

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
  if [ "$ROTATE" = "--rotate" ] || [ "$ROTATE" = "--rotate-roles" ]; then
    val=""
  else
    val="$(prev "${RELEASE}-database-secret" "$key")"
  fi
  [ -n "$val" ] || { val="$(gen)"; echo "  ${key} : généré"; }
  db_args+=(--from-literal="${key}=${val}")
done
db_args+=(
  --from-literal=ADMIN_EMAIL="${APPADMINEMAIL}"
  --from-literal=ADMIN_PASSWORD="${APPADMINPWD}"
)

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

# MAIR-131: Cockpit token, cannot be generated (issued from the Cockpit
# console). Kept from the cluster when not supplied; --rotate does not clear it.
COCKPITTOKEN="${COCKPIT_TOKEN:-}"
if [ -n "$COCKPITTOKEN" ]; then
  echo "  COCKPIT_TOKEN    : from COCKPIT_TOKEN"
else
  COCKPITTOKEN="$(prev "${RELEASE}-cockpit-secret" COCKPIT_TOKEN)"
  if [ -n "$COCKPITTOKEN" ]; then
    echo "  COCKPIT_TOKEN    : kept from cluster"
  fi
fi

# MAIR-498: erasure credentials of the compliance service, issued elsewhere
# (Keycloak admin console, Resend, Object Storage): never generated, kept from
# the cluster when not supplied.
COMPLIANCE_KEYS="KEYCLOAK_ADMIN_CLIENT_SECRET RESEND_API_KEY S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY SCW_SECRET_KEY"
compliance_args=()
for key in $COMPLIANCE_KEYS; do
  case "$key" in
    KEYCLOAK_ADMIN_CLIENT_SECRET) var=COMPLIANCE_KEYCLOAK_CLIENT_SECRET ;;
    *) var="COMPLIANCE_${key}" ;;
  esac
  val="${!var:-}"
  if [ -n "$val" ]; then
    echo "  compliance ${key} : from ${var}"
  else
    val="$(prev "${RELEASE}-compliance-secret" "$key")"
    [ -z "$val" ] || echo "  compliance ${key} : kept from cluster"
  fi
  [ -z "$val" ] || compliance_args+=(--from-literal="${key}=${val}")
done

GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"

# MAIR-119: unlike the other secrets, these are credentials for an external
# S3 bucket and can't be generated: taken from the environment, else kept from
# the cluster (a re-run without them must not drop the backup-secret). Skip
# the backup-secret entirely if backup isn't provisioned for this instance yet.
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
if [ -z "$AWS_ACCESS_KEY_ID" ] && [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  AWS_ACCESS_KEY_ID="$(prev "${RELEASE}-backup-secret" AWS_ACCESS_KEY_ID)"
  AWS_SECRET_ACCESS_KEY="$(prev "${RELEASE}-backup-secret" AWS_SECRET_ACCESS_KEY)"
  [ -z "$AWS_ACCESS_KEY_ID" ] || echo "  AWS_*            : kept from cluster"
fi

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

kubectl create secret generic "${RELEASE}-keycloak-secret" \
  --namespace "$NS" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KCADMINPWD" \
  --from-literal=KEYCLOAK_DB_PASSWORD="$KCDBPWD" \
  --from-literal=BFF_USER_CLIENT_SECRET="$KCBFFSECRET" \
  --dry-run=client -o yaml | seal > "$TMP/keycloak.yaml"

if [ -n "$GHCR_TOKEN" ]; then
  kubectl create secret docker-registry ghcr-secret \
    --namespace "$NS" --docker-server=ghcr.io \
    --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | seal > "$TMP/ghcr.yaml"
fi

# MAIR-500: API key of Scaleway Key Manager for the sealed backups
# (backup.sealing), never generated; kept from the cluster when not supplied.
BACKUP_SCW_SECRET_KEY="${BACKUP_SCW_SECRET_KEY:-}"
if [ -z "$BACKUP_SCW_SECRET_KEY" ]; then
  BACKUP_SCW_SECRET_KEY="$(prev "${RELEASE}-backup-secret" SCW_SECRET_KEY)"
  [ -z "$BACKUP_SCW_SECRET_KEY" ] || echo "  backup SCW_SECRET_KEY : kept from cluster"
fi
backup_args=()
[ -z "$BACKUP_SCW_SECRET_KEY" ] || backup_args+=(--from-literal=SCW_SECRET_KEY="$BACKUP_SCW_SECRET_KEY")

if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
  kubectl create secret generic "${RELEASE}-backup-secret" \
    --namespace "$NS" \
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --from-literal=RESTIC_PASSWORD="$RESTICPASS" \
    "${backup_args[@]}" \
    --dry-run=client -o yaml | seal > "$TMP/backup.yaml"
else
  echo "  backup-secret : skipped (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY not provided)"
fi

if [ -n "$COCKPITTOKEN" ]; then
  kubectl create secret generic "${RELEASE}-cockpit-secret" \
    --namespace "$NS" \
    --from-literal=COCKPIT_TOKEN="$COCKPITTOKEN" \
    --dry-run=client -o yaml | seal > "$TMP/cockpit.yaml"
else
  echo "  cockpit-secret : skipped (COCKPIT_TOKEN not provided)"
fi

if [ "${#compliance_args[@]}" -gt 0 ]; then
  kubectl create secret generic "${RELEASE}-compliance-secret" \
    --namespace "$NS" "${compliance_args[@]}" \
    --dry-run=client -o yaml | seal > "$TMP/compliance.yaml"
else
  echo "  compliance-secret : skipped (no COMPLIANCE_* credential provided)"
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
  echo "# Rotate only the API Postgres role passwords (applied by the next Liquibase sync):"
  echo "#   ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV} --rotate-roles"
  echo "# Change the Resend API key (SMTP_PASSWORD of core-api):"
  echo "#   RESEND_API_KEY=re_xxx ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV}"
  echo "# Change the Object Storage key pair (S3_ACCESS_KEY / S3_SECRET_KEY of elearning-api):"
  echo "#   S3_ACCESS_KEY=SCW... S3_SECRET_KEY=... ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV}"
  echo "# Set the admin account's e-mail (MAIR-170, ADMIN_PASSWORD is generated once unless set,"
  echo "# sealed as its argon2id hash, MAIR-414):"
  echo "#   ADMIN_EMAIL=admin@example.org ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV}"
  echo "# Re-seal a bff-user client secret regenerated in the Keycloak admin console (MAIR-139):"
  echo "#   BFF_USER_CLIENT_SECRET=... ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV}"
  echo "# Change the Cockpit token (OpenTelemetry Collector, MAIR-131):"
  echo "#   COCKPIT_TOKEN=... ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV}"
  echo "# Set the erasure credentials of the compliance service (MAIR-498):"
  echo "#   COMPLIANCE_KEYCLOAK_CLIENT_SECRET=... COMPLIANCE_RESEND_API_KEY=... ./scripts/seal-secrets.sh ${CTX} ${ORG} ${ENV}"
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
