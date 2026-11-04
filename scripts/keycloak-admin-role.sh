#!/usr/bin/env bash
# =============================================================================
# Gives the realm roles of charts/keycloak `realm.roles[].clientComposites`
# (MAIR-610: `Admin` includes the realm-management user roles, so a town hall
# Admin administers the realm's users from Keycloak's console) to a realm that
# already exists. Keycloak imports the realm only into an empty database, so
# instances deployed before MAIR-610 have a plain `Admin` role.
#
#   ./scripts/keycloak-admin-role.sh <kube-context> <env>
#
# Run it where kubectl reaches the instance (the group's Argo CD machine, like
# scripts/keycloak-2fa.sh), once Argo CD synced the chart version carrying
# MAIR-610. The composites are read from the realm ConfigMap the chart rendered
# (<release>-keycloak-realm), so the script and the import never diverge.
# Idempotent and additive: a missing role is created, the listed client roles
# are added to it (adding one it already has changes nothing), nothing is
# removed. The role's composites are printed at the end.
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

for bin in kubectl jq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done
K=(kubectl --context "$CTX" -n "$NS")

secret_key() {
  "${K[@]}" get secret "${RELEASE}-keycloak-secret" -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true
}
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-$(secret_key KEYCLOAK_ADMIN_PASSWORD)}"
[ -n "$ADMIN_PASSWORD" ] || { echo "no Keycloak admin password (KEYCLOAK_ADMIN_PASSWORD)" >&2; exit 1; }

DEF="$("${K[@]}" get configmap "${RELEASE}-keycloak-realm" -o json | jq -c --arg key "${REALM}-realm.json" '.data[$key] | fromjson')"
ROLES="$(jq -c '[.roles.realm[] | select((.composites.client // {}) | length > 0)]' <<<"$DEF")"
[ "$(jq length <<<"$ROLES")" -gt 0 ] || {
  echo "${RELEASE}-keycloak-realm has no composite role: sync the chart version with MAIR-610 first." >&2
  exit 1
}

# kcadm <args...>: runs kcadm.sh in the Keycloak pod with a throwaway admin
# session. stdin: the admin password on the first line, then whatever kcadm
# reads with `-f -`.
kcadm() {
  "${K[@]}" exec -i "deploy/${RELEASE}-keycloak" -c keycloak -- sh -c '
    read -r P
    C=$(mktemp /tmp/kcadm.XXXXXX)
    trap "rm -f $C" EXIT
    /opt/keycloak/bin/kcadm.sh config credentials --config "$C" --server http://localhost:8080 \
      --realm master --user "$0" --password "$P" >/dev/null 2>&1 \
      || { echo "Keycloak refused the admin login (set KEYCLOAK_ADMIN_PASSWORD)" >&2; exit 3; }
    /opt/keycloak/bin/kcadm.sh "$@" --config "$C"
  ' "$ADMIN_USER" "$@"
}
kc() { printf '%s\n' "$ADMIN_PASSWORD" | kcadm "$@"; }
kc_with() { { printf '%s\n' "$ADMIN_PASSWORD"; printf '%s' "$1"; } | kcadm "${@:2}"; }
path() { jq -rn --arg s "$1" '$s | @uri'; }

echo "Context: ${CTX}  Namespace: ${NS}  Realm: ${REALM}"

while read -r role; do
  name="$(jq -r .name <<<"$role")"
  if ! kc get "roles/$(path "$name")" -r "$REALM" >/dev/null 2>&1; then
    kc_with "$(jq -c '{name, description}' <<<"$role")" create roles -r "$REALM" -f - >/dev/null
    echo "  role ${name}: created"
  fi
  while read -r client; do
    args=()
    while read -r r; do args+=(--rolename "$r"); done < <(jq -r --arg c "$client" '.composites.client[$c][]' <<<"$role")
    kc add-roles -r "$REALM" --rname "$name" --cclientid "$client" "${args[@]}"
    echo "  role ${name} includes ${client}: $(kc get-roles -r "$REALM" --rname "$name" --cclientid "$client" \
      | jq -r '[.[].name] | sort | join(", ")')"
  done < <(jq -r '.composites.client | keys[]' <<<"$role")
done < <(jq -c '.[]' <<<"$ROLES")
