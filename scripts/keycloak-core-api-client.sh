#!/usr/bin/env bash
# =============================================================================
# Creates or updates the `core-api` client (MAIR-554) in a realm that already
# exists. Keycloak imports charts/keycloak's realm only into an empty
# database, so instances deployed before MAIR-554 never got this client.
#
#   ./scripts/keycloak-core-api-client.sh <kube-context> <env>
#
# Run it where kubectl reaches the instance (the group's Argo CD machine, like
# scripts/seal-secrets.sh), after secrets.yaml with CORE_API_CLIENT_SECRET is
# synced. Idempotent: it (re)writes the client from the same definition as
# templates/realm-configmap.yaml, sets its secret to the sealed
# CORE_API_CLIENT_SECRET and grants its service account the realm-management
# roles Core needs. It then restarts core-api so it reads the secret.
#
# The admin of the master realm is `admin` with the sealed
# KEYCLOAK_ADMIN_PASSWORD, read on the first start only: if it was changed in
# Keycloak since, pass the current one in KEYCLOAK_ADMIN_PASSWORD.
# Passwords only travel on kubectl exec's stdin, never in a command line.
#
# Needs kubectl and jq. KEYCLOAK_REALM overrides the realm (default mairie360).
# =============================================================================
set -euo pipefail

CTX="${1:?usage: $0 <kube-context> <env>}"
ENV="${2:?usage: $0 <kube-context> <env>}"
NS="mairie360-${ENV}"
RELEASE="${ENV}"
REALM="${KEYCLOAK_REALM:-mairie360}"
ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
CLIENT_ID="core-api"
# Same list as charts/keycloak/values.yaml realm.clients.coreApi.serviceAccountRoles.
ROLES=(manage-users view-realm manage-realm)

for bin in kubectl jq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done
K=(kubectl --context "$CTX" -n "$NS")

secret_key() {
  "${K[@]}" get secret "${RELEASE}-keycloak-secret" -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true
}

CLIENT_SECRET="$(secret_key CORE_API_CLIENT_SECRET)"
[ -n "$CLIENT_SECRET" ] || {
  echo "CORE_API_CLIENT_SECRET is missing from ${RELEASE}-keycloak-secret: run scripts/seal-secrets.sh, push, sync, then retry." >&2
  exit 1
}
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-$(secret_key KEYCLOAK_ADMIN_PASSWORD)}"
[ -n "$ADMIN_PASSWORD" ] || { echo "no Keycloak admin password (KEYCLOAK_ADMIN_PASSWORD)" >&2; exit 1; }

# kcadm <args...>: runs kcadm.sh in the Keycloak pod with a throwaway admin
# session. stdin: the admin password on the first line, then whatever kcadm
# reads with `-f -`.
kcadm() {
  "${K[@]}" exec -i "deploy/${RELEASE}-keycloak" -c keycloak -- sh -c '
    read -r P
    C=$(mktemp /tmp/kcadm.XXXXXX)
    trap "rm -f $C" EXIT
    /opt/keycloak/bin/kcadm.sh config credentials --config "$C" --server http://localhost:8080 \
      --realm master --user "$0" --password "$P" >/dev/null \
      || { echo "Keycloak refused the admin login (set KEYCLOAK_ADMIN_PASSWORD)" >&2; exit 3; }
    /opt/keycloak/bin/kcadm.sh "$@" --config "$C"
  ' "$ADMIN_USER" "$@"
}
kc() { printf '%s\n' "$ADMIN_PASSWORD" | kcadm "$@"; }
kc_with() { { printf '%s\n' "$ADMIN_PASSWORD"; printf '%s' "$1"; } | kcadm "${@:2}"; }

echo "Context: ${CTX}  Namespace: ${NS}  Realm: ${REALM}"

# Login URLs: the same as bff-user's, which the realm import derived from
# global.domain (https://login.<domain>).
BFF="$(kc get clients -r "$REALM" -q clientId=bff-user --fields clientId,rootUrl,redirectUris,webOrigins \
  | jq -c '[.[] | select(.clientId == "bff-user")][0] // empty')"
[ -n "$BFF" ] || { echo "client bff-user not found in realm ${REALM}: is the realm imported?" >&2; exit 1; }

BODY="$(jq -cn --arg id "$CLIENT_ID" --arg secret "$CLIENT_SECRET" --argjson bff "$BFF" '{
  clientId: $id,
  name: "Core_API",
  description: "Mairie 360 Core API (confidential client: sign-in code exchange + realm administration service account, MAIR-554)",
  enabled: true,
  protocol: "openid-connect",
  publicClient: false,
  clientAuthenticatorType: "client-secret",
  secret: $secret,
  standardFlowEnabled: true,
  implicitFlowEnabled: false,
  directAccessGrantsEnabled: false,
  serviceAccountsEnabled: true,
  rootUrl: $bff.rootUrl,
  redirectUris: $bff.redirectUris,
  webOrigins: $bff.webOrigins,
  attributes: {"pkce.code.challenge.method": "S256", "post.logout.redirect.uris": "+"}
}')"

UUID="$(kc get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id,clientId \
  | jq -r --arg id "$CLIENT_ID" '[.[] | select(.clientId == $id)][0].id // empty')"
if [ -n "$UUID" ]; then
  kc_with "$BODY" update "clients/${UUID}" -r "$REALM" -f - >/dev/null
  echo "  client ${CLIENT_ID}: updated"
else
  kc_with "$BODY" create clients -r "$REALM" -f - >/dev/null
  echo "  client ${CLIENT_ID}: created"
fi

role_args=()
for r in "${ROLES[@]}"; do role_args+=(--rolename "$r"); done
kc add-roles -r "$REALM" --uusername "service-account-${CLIENT_ID}" --cclientid realm-management "${role_args[@]}"
granted="$(kc get-roles -r "$REALM" --uusername "service-account-${CLIENT_ID}" --cclientid realm-management | jq -r '[.[].name] | sort | join(" ")')"
echo "  service-account-${CLIENT_ID} realm-management roles: ${granted}"
for r in "${ROLES[@]}"; do
  [[ " ${granted} " == *" ${r} "* ]] || { echo "role ${r} missing on service-account-${CLIENT_ID}" >&2; exit 1; }
done

# bff-user must not administer the realm (MAIR-554 acceptance criterion).
bff_roles="$(kc get-roles -r "$REALM" --uusername service-account-bff-user --cclientid realm-management | jq -r '[.[].name] | join(" ")')"
if [ -n "$bff_roles" ]; then
  echo "WARNING: service-account-bff-user has realm-management roles: ${bff_roles}" >&2
fi

# Core reads KEYCLOAK_CLIENT_SECRET at start only.
"${K[@]}" rollout restart "deploy/${RELEASE}-core-api" >/dev/null
echo "  ${RELEASE}-core-api restarted"
