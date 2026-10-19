#!/usr/bin/env bash
# =============================================================================
# Applies the optional second factor (MAIR-572) to a realm that already
# exists. Keycloak imports charts/keycloak's realm only into an empty
# database, so instances deployed before MAIR-572 keep the built-in browser
# flow, where WebAuthn is disabled.
#
#   ./scripts/keycloak-2fa.sh <kube-context> <env>
#
# Run it where kubectl reaches the instance (the group's Argo CD machine, like
# scripts/seal-secrets.sh), once Argo CD synced the chart version carrying
# MAIR-572. The definition is read from the realm ConfigMap the chart
# rendered (<release>-keycloak-realm), so the script and the import never
# diverge: it sets the OTP policy, (re)creates the "mairie360 browser" flows
# and makes them the realm's browser flow. Idempotent: an existing
# "mairie360 browser" flow is replaced by the ConfigMap's one. Credentials
# agents already registered (OTP, WebAuthn) are kept.
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
BROWSER_FLOW="$(jq -r '.browserFlow // empty' <<<"$DEF")"
[ -n "$BROWSER_FLOW" ] && jq -e '.authenticationFlows | length > 0' <<<"$DEF" >/dev/null || {
  echo "${RELEASE}-keycloak-realm has no browser flow: sync the chart version with MAIR-572 first." >&2
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
# Flow aliases contain spaces: they are path segments of the admin API.
path() { jq -rn --arg s "$1" '$s | @uri'; }

echo "Context: ${CTX}  Namespace: ${NS}  Realm: ${REALM}"

# 1. OTP policy, from the same realm fields as the import.
OTP="$(jq -c 'with_entries(select(.key | startswith("otpPolicy")))' <<<"$DEF")"
kc_with "$OTP" update "realms/${REALM}" -f - >/dev/null
echo "  OTP policy: $(jq -r '"\(.otpPolicyType) \(.otpPolicyAlgorithm) \(.otpPolicyDigits) digits \(.otpPolicyPeriod) s"' <<<"$OTP")"

# 2. Replace the flows. The realm must not point at a flow being deleted.
kc update "realms/${REALM}" -s browserFlow=browser >/dev/null
EXISTING="$(kc get authentication/flows -r "$REALM" --fields id,alias \
  | jq -r --arg a "$BROWSER_FLOW" '[.[] | select(.alias == $a)][0].id // empty')"
if [ -n "$EXISTING" ]; then
  kc delete "authentication/flows/${EXISTING}" -r "$REALM"
  echo "  flow ${BROWSER_FLOW}: removed, recreating"
fi

flow_def() { jq -c --arg a "$1" '[.authenticationFlows[] | select(.alias == $a)][0]' <<<"$DEF"; }
REQUIREMENTS=()
# add_executions <flow alias>: creates its executions in priority order, depth
# first, which is also the order the admin API lists them in.
add_executions() {
  local parent="$1" execution
  while read -r execution; do
    REQUIREMENTS+=("$(jq -r .requirement <<<"$execution")")
    if [ "$(jq -r .authenticatorFlow <<<"$execution")" = true ]; then
      local sub; sub="$(jq -r .flowAlias <<<"$execution")"
      kc_with "$(flow_def "$sub" | jq -c '{alias, description, type: .providerId, provider: "registration-page-form"}')" \
        create "authentication/flows/$(path "$parent")/executions/flow" -r "$REALM" -f - >/dev/null
      add_executions "$sub"
    else
      kc create "authentication/flows/$(path "$parent")/executions/execution" -r "$REALM" \
        -s provider="$(jq -r .authenticator <<<"$execution")" >/dev/null
    fi
  done < <(flow_def "$parent" | jq -c '.authenticationExecutions | sort_by(.priority)[]')
}
kc_with "$(flow_def "$BROWSER_FLOW" | jq -c '{alias, description, providerId, topLevel: true, builtIn: false}')" \
  create authentication/flows -r "$REALM" -f - >/dev/null
add_executions "$BROWSER_FLOW"

CREATED="$(kc get "authentication/flows/$(path "$BROWSER_FLOW")/executions" -r "$REALM")"
[ "$(jq length <<<"$CREATED")" -eq "${#REQUIREMENTS[@]}" ] || { echo "unexpected executions in ${BROWSER_FLOW}" >&2; exit 1; }
for i in "${!REQUIREMENTS[@]}"; do
  kc_with "$(jq -c --argjson i "$i" --arg r "${REQUIREMENTS[$i]}" '.[$i] | {id, requirement: $r}' <<<"$CREATED")" \
    update "authentication/flows/$(path "$BROWSER_FLOW")/executions" -r "$REALM" -f - >/dev/null
done
kc update "realms/${REALM}" -s browserFlow="$BROWSER_FLOW" >/dev/null

kc get "authentication/flows/$(path "$BROWSER_FLOW")/executions" -r "$REALM" \
  | jq -r '.[] | "  " + ("  " * .level) + .displayName + ": " + .requirement'
echo "  browser flow: $(kc get "realms/${REALM}" --fields browserFlow | jq -r .browserFlow)"
