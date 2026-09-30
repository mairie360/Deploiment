#!/usr/bin/env bash
# =============================================================================
# Acceptance test of a deployed instance.
#
#   ./scripts/verify.sh <kube-context> <env> [domain]
#
# Exits non-zero if any check fails: usable as is as a CI step (the Promote
# workflow runs it against staging before prod moves, MAIR-346) or at the end
# of an Ansible playbook.
#
# Needs: bash, kubectl, curl, openssl, getent, timeout, base64, od, awk.
#
# -----------------------------------------------------------------------------
# Kubernetes permissions (MAIR-346). The Promote workflow runs this script on
# the Argo CD machine's self-hosted runner with a ServiceAccount that ansible
# binds to exactly this; keep the list in sync with the script. It
# deliberately needs no Secret read and no pods/exec: Secret keys are checked
# on the SealedSecrets (whose ciphertext length gives the plaintext length),
# and every in-cluster probe is a throwaway curl pod.
#
#   namespace mairie360-<env>
#     ""           pods                  get list watch create delete
#     ""           pods/attach           create
#     ""           pods/log              get
#     ""           services              list
#     ""           endpoints             get
#     apps         deployments           get list watch
#     batch        jobs                  get list
#     batch        cronjobs              get
#     bitnami.com  sealedsecrets         get
#   namespace kube-system
#     apps         daemonsets            get list watch   resourceNames: cilium
#     apps         deployments           get list watch   resourceNames: hubble-relay
#
# `pods create` would let a pod mount any Secret of the namespace: ansible is
# expected to pair it with an admission policy that only admits the probe
# pods this script creates, i.e. name `verify-probe-*`, one container of
# image curlimages/curl:8.10.1, no volumes, no env, no service account token
# (see probe() below).
#
# Network: steps 13-15 reach the instance's PUBLIC hostnames (443, 80 and a
# port scan) from wherever the script runs; everything else goes through the
# Kubernetes API server of <kube-context>.
# =============================================================================
set -uo pipefail

CTX="${1:?usage: $0 <kube-context> <env> [domain]}"
ENV="${2:?}"
DOMAIN="${3:-}"
# Realm provisioned by charts/keycloak (global.keycloak.realm).
KEYCLOAK_REALM="${KEYCLOAK_REALM:-mairie360}"
# One machine = one cluster = one mairie360-<env> namespace.
NS="mairie360-${ENV}"
RELEASE="${ENV}"
K="kubectl --context ${CTX} -n ${NS}"
PROBE_IMAGE="curlimages/curl:8.10.1"
FAILED=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
ko()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }

# probe <name> <labels|""> <curl args...>: runs curl once in a throwaway pod
# of the instance namespace and prints its output. Always the same shape (see
# the admission policy note above).
probe() {
  local name="verify-probe-$1" labels="$2"; shift 2
  $K run "$name" --rm -i --restart=Never --image="$PROBE_IMAGE" \
    ${labels:+--labels="$labels"} --timeout=60s \
    --overrides='{"apiVersion":"v1","spec":{"automountServiceAccountToken":false}}' \
    -- "$@"
}

# sealed_len <sealedsecret> <key>: plaintext length of one key of a
# SealedSecret, from its ciphertext alone (no Secret read). sealed-secrets'
# hybrid encryption writes a 2-byte big-endian length L, the L-byte RSA-OAEP
# session key, then AES-GCM(plaintext) with a 16-byte tag, so
# plaintext = total - 2 - L - 16. Prints -1 when the key is absent.
sealed_len() {
  local ct total hdr
  ct=$($K get sealedsecret "$1" -o jsonpath="{.spec.encryptedData['$2']}" 2>/dev/null)
  [ -n "$ct" ] || { echo -1; return; }
  total=$(printf '%s' "$ct" | base64 -d 2>/dev/null | wc -c)
  hdr=$(printf '%s' "$ct" | base64 -d 2>/dev/null | head -c 2 | od -An -tu1)
  # shellcheck disable=SC2086 # two numbers, split on purpose
  set -- $hdr
  echo $(( total - 2 - (${1:-0} * 256 + ${2:-0}) - 16 ))
}

step 1 "Every pod is Running or Completed"
BAD=$($K get pods --no-headers 2>/dev/null | grep -vE 'Running|Completed' || true)
[ -z "$BAD" ] && ok "no pod in error" || { ko "unhealthy pods"; echo "$BAD"; }

step 2 "No restart loop"
LOOP=$($K get pods --no-headers 2>/dev/null | awk '$4 > 5 {print $1, $4}' || true)
[ -z "$LOOP" ] && ok "no CrashLoop" || { ko "repeated restarts"; echo "$LOOP"; }

step 3 "Services have endpoints (selectors match)"
EMPTY=""
for svc in $($K get svc -o name 2>/dev/null | cut -d/ -f2); do
  case "$svc" in *-hl) continue;; esac
  EP=$($K get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  [ -z "$EP" ] && EMPTY="$EMPTY $svc"
done
[ -z "$EMPTY" ] && ok "every Service points at pods" || ko "Services without endpoints:$EMPTY"

step 4 "The expected Secrets are unsealed and carry their keys"
for s in "${RELEASE}-app-secrets" "${RELEASE}-database-secret" "${RELEASE}-redis" "${RELEASE}-keycloak-secret"; do
  SYNCED=$($K get sealedsecret "$s" -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null)
  case "$SYNCED" in
    True) ok "$s unsealed" ;;
    "")   ko "$s: no SealedSecret, or not processed yet (scripts/seal-secrets.sh?)" ;;
    *)    ko "$s: SealedSecret not unsealed (sealed with another machine's key?)" ;;
  esac
done

# key_set <sealedsecret> <key> <consequence when empty>
key_set() {
  if [ "$(sealed_len "$1" "$2")" -gt 0 ]; then ok "$2 is set"; else ko "$2 empty in $1: $3"; fi
}
key_set "${RELEASE}-app-secrets" SMTP_PASSWORD \
  "core-api cannot send e-mails (RESEND_API_KEY=… scripts/seal-secrets.sh)"
for k in S3_ACCESS_KEY S3_SECRET_KEY; do
  key_set "${RELEASE}-app-secrets" "$k" \
    "elearning-api cannot start (S3_ACCESS_KEY=… S3_SECRET_KEY=… scripts/seal-secrets.sh)"
done
for k in ADMIN_EMAIL ADMIN_PASSWORD; do
  key_set "${RELEASE}-database-secret" "$k" \
    "admin account stays on its changelog template credentials (MAIR-170, ADMIN_EMAIL=… scripts/seal-secrets.sh)"
done

step 5 "No plaintext secret in the deployed manifests"
if $K get deploy -o yaml 2>/dev/null | grep -q 'value: .b"secret"'; then
  ko "plaintext JWT_SECRET found"
else
  ok "no plaintext secret value"
fi

step 6 "Redis requires authentication"
# Unauthenticated PING from a bff-labelled pod (admitted on 6379 by the redis
# NetworkPolicy): the ACL must answer NOAUTH, never PONG. No pods/exec needed.
REPLY=$(probe redis "app.kubernetes.io/component=bff" \
          curl -s -m 5 "gopher://${RELEASE}-redis:6379/_PING%0D%0AQUIT%0D%0A" 2>/dev/null || true)
case "$REPLY" in
  *PONG*)          ko "Redis answers WITHOUT authentication" ;;
  *NOAUTH*|*-ERR*) ok "Redis refuses unauthenticated connections" ;;
  *)               ko "no answer from ${RELEASE}-redis:6379 (pod down, or NetworkPolicy)" ;;
esac

step 7 "The Liquibase migration succeeded"
if $K get job "${RELEASE}-liquibase" >/dev/null 2>&1; then
  S=$($K get job "${RELEASE}-liquibase" -o jsonpath='{.status.succeeded}')
  [ "${S:-0}" -ge 1 ] && ok "job complete" || ko "job not complete"
else
  ok "job already cleaned up (hook deleted after success)"
fi

step 8 "Network isolation: an API is NOT reachable without the bff label"
if probe deny "" curl -s -m 5 "http://${RELEASE}-core-api:3000/health" >/dev/null 2>&1; then
  ko "an arbitrary pod reaches core-api: NetworkPolicy not enforced"
else
  ok "unauthorised traffic blocked"
fi

step 9 "Network isolation: a bff-labelled pod reaches the API"
if probe allow "app.kubernetes.io/component=bff" \
     curl -sf -m 5 "http://${RELEASE}-core-api:3000/health" >/dev/null 2>&1; then
  ok "authorised traffic accepted"
else
  ko "a bff pod cannot reach core-api (policy too strict, or API down)"
fi

step 10 "Cilium enforces the policies and Hubble records the flows"
KS="kubectl --context ${CTX} -n kube-system"
if $KS rollout status daemonset/cilium --timeout=10s >/dev/null 2>&1; then
  ok "cilium agent Ready (NetworkPolicies enforced, flows recorded)"
else
  ko "cilium agent not Ready: CNI still flannel? (Ansible role k8s_node)"
fi
if $KS rollout status deployment/hubble-relay --timeout=10s >/dev/null 2>&1; then
  ok "hubble-relay available (scripts/hubble-flows.sh ${CTX} ${ENV})"
else
  ko "hubble-relay unavailable"
fi

step 11 "MAIR-119/MAIR-231: the latest backup Job succeeded (Mairie360 DB + Keycloak DB when enabled)"
if $K get cronjob "${RELEASE}-backup" >/dev/null 2>&1; then
  LATEST=$($K get jobs -l app.kubernetes.io/component=backup \
             --sort-by=.status.startTime -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
  if [ -z "$LATEST" ]; then
    ok "backup CronJob present, no Job has run yet"
  else
    S=$($K get job "$LATEST" -o jsonpath='{.status.succeeded}' 2>/dev/null)
    # A single Job dumps both databases in sequence (set -euo pipefail), so
    # "succeeded" already covers the Keycloak dump when backup.keycloak.enabled.
    [ "${S:-0}" -ge 1 ] && ok "backup $LATEST succeeded" || ko "backup $LATEST failed or still running"
  fi
else
  ok "backup not enabled for this instance"
fi

step 12 "MAIR-139: Keycloak serves the ${KEYCLOAK_REALM} realm"
if $K get deploy "${RELEASE}-keycloak" >/dev/null 2>&1; then
  if $K rollout status "deploy/${RELEASE}-keycloak" --timeout=10s >/dev/null 2>&1; then
    ok "keycloak Deployment available"
  else
    ko "keycloak Deployment not available (kubectl logs deploy/${RELEASE}-keycloak)"
  fi
  if probe keycloak "app.kubernetes.io/component=bff" \
       curl -sf -m 10 "http://${RELEASE}-keycloak:8080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" \
       2>/dev/null | grep -q '"issuer":"https://'; then
    ok "realm ${KEYCLOAK_REALM} imported, issuer on https"
  else
    ko "realm ${KEYCLOAK_REALM} not served from a bff pod (import failed, or NetworkPolicy)"
  fi
else
  ok "keycloak not enabled for this instance"
fi

if [ -n "$DOMAIN" ]; then
  step 13 "TLS certificate verified on https://login.${DOMAIN} and https://auth.${DOMAIN}"
  for host in "login.${DOMAIN}" "auth.${DOMAIN}"; do
    ISSUER=$(echo | openssl s_client -connect "${host}:443" \
               -servername "${host}" 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null || true)
    # STAGING first: its issuer ("(STAGING) Let's Encrypt") matches both.
    case "$ISSUER" in
      *STAGING*) ko "${host}: Let's Encrypt STAGING certificate (not trusted by browsers)" ;;
      *"Let's Encrypt"*) ok "${host}: issued by Let's Encrypt" ;;
      *) ko "${host}: unexpected certificate: ${ISSUER:-none}" ;;
    esac
  done

  step 14 "HTTP redirects to HTTPS"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://login.${DOMAIN}" || true)
  case "$CODE" in 301|302|308) ok "redirect $CODE" ;; *) ko "code $CODE" ;; esac

  step 15 "Only the fronts and Keycloak are exposed (6443 must be on the VPN, not public)"
  IP=$(getent hosts "login.${DOMAIN}" | awk '{print $1}' | head -1)
  for p in 3000 4000 5432 6379 6443 8080 9000; do
    if timeout 3 bash -c "</dev/tcp/${IP}/${p}" 2>/dev/null; then
      ko "port ${p} open on the Internet"
    else
      ok "port ${p} closed"
    fi
  done
fi

echo
[ $FAILED -eq 0 ] && { echo "Acceptance OK"; exit 0; } || { echo "Acceptance FAILED"; exit 1; }
