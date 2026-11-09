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
# the two checks that need a plaintext value are skipped when
# `kubectl auth can-i get secrets` says no (step 4), and every in-cluster
# probe is a throwaway curl pod.
#
#   namespace mairie360-<env>
#     ""           pods                  get list watch create delete
#     ""           pods/attach           create
#     ""           pods/log              get
#     ""           services              list
#     ""           endpoints             get
#     apps         deployments           get list watch
#     batch        jobs                  get list
#     batch        cronjobs              get list
#     apps         statefulsets          list
#     bitnami.com  sealedsecrets         get
#   namespace kube-system
#     apps         daemonsets            get list watch   resourceNames: cilium
#     apps         deployments           get list watch   resourceNames: hubble-relay
#
# `pods create` would let a pod mount any Secret of the namespace: ansible is
# expected to pair it with an admission policy that only admits the probe
# pods this script creates, i.e. name `verify-probe-*`, one container of
# image curlimages/curl:8.10.1, no volumes, no env, no service account token,
# no command, lifecycle hook nor probe (see probe() below).
#
# Network: steps 13-15 reach the instance's PUBLIC hostnames (443, 80 and a
# port scan) from wherever the script runs; everything else goes through the
# Kubernetes API server of <kube-context>.
# =============================================================================
set -uo pipefail

# shellcheck source=scripts/lib/secret-values.sh
. "$(dirname "$0")/lib/secret-values.sh"

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

key_set "${RELEASE}-database-secret" ADMIN_EMAIL \
  "the Liquibase Job refuses to migrate (MAIR-414, ADMIN_EMAIL=… scripts/seal-secrets.sh)"
key_set "${RELEASE}-keycloak-secret" CORE_API_CLIENT_SECRET \
  "core-api cannot administer the realm (MAIR-554, scripts/seal-secrets.sh then scripts/keycloak-core-api-client.sh)"

# Checks on the plaintext values themselves need a Secret read, which the
# Promote workflow's runner does not have (MAIR-346, see the header). There
# they are skipped: what they guard against still fails this script, through
# the Liquibase Job (step 7, ADMIN_PASSWORD) or the APIs crash-looping
# (steps 1-2, a password that is not URL-safe). Run by hand with an admin
# context, they are checked.
if $K auth can-i get secrets >/dev/null 2>&1; then
  case "$($K get secret "${RELEASE}-database-secret" -o jsonpath="{.data.ADMIN_PASSWORD}" 2>/dev/null | base64 -d 2>/dev/null)" in
    '$argon2id$'*) ok "ADMIN_PASSWORD is an argon2id hash" ;;
    *) ko "ADMIN_PASSWORD in ${RELEASE}-database-secret is empty or plaintext: the Liquibase Job refuses to migrate (MAIR-414, re-run scripts/seal-secrets.sh)" ;;
  esac

  # MAIR-531: the APIs put these passwords raw in REDIS_URL / their postgres://
  # URL, a base64 one ("/", "+", "=") fails with "Redis URL did not parse".
  # Keys are read from the live Secrets, so the chart's role lists stay the
  # source of truth.
  for spec in "${RELEASE}-redis:-password" "${RELEASE}-database-secret:_PASSWORD"; do
    s="${spec%%:*}"; suffix="${spec#*:}"
    for key in $($K get secret "$s" -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null \
                   | grep -- "${suffix}\$" | grep -v '^ADMIN_PASSWORD$\|^POSTGRES_PASSWORD$\|^redis-password$'); do
      val="$($K get secret "$s" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null)"
      if url_safe "$val"; then
        ok "$s/$key is URL-safe"
      else
        ko "$s/$key is empty or not URL-safe: its API cannot build its URL (MAIR-531, re-run scripts/seal-secrets.sh then restart Redis and the APIs)"
      fi
    done
  done
else
  ok "no Secret read with this context: ADMIN_PASSWORD format and URL-safe passwords skipped (covered by steps 1, 2 and 7)"
fi

step 5 "No plaintext secret in the deployed manifests"
if $K get deploy -o yaml 2>/dev/null | grep -q 'value: .b"secret"'; then
  ko "plaintext JWT_SECRET found"
else
  ok "no plaintext secret value"
fi

step 5b "MAIR-680: core-api alone gets the session signing key (JWT_PRIVATE_KEY)"
# Every Deployment / StatefulSet / CronJob container (and init container)
# that reads JWT_PRIVATE_KEY, as "<kind>/<name>"; only <env>-core-api may.
# A CronJob's pod template sits under spec.jobTemplate.spec.template.
# A refused or failed read is a FAIL, never an empty list read as "no signer".
if SIGNERS="$($K get deploy,statefulset,cronjob -o go-template='{{range .items}}{{$o := printf "%s/%s" .kind .metadata.name}}{{$t := .spec.template}}{{with .spec.jobTemplate}}{{$t = .spec.template}}{{end}}{{with $t}}{{range .spec.containers}}{{range .env}}{{if eq .name "JWT_PRIVATE_KEY"}}{{$o}}{{"\n"}}{{end}}{{end}}{{end}}{{range .spec.initContainers}}{{range .env}}{{if eq .name "JWT_PRIVATE_KEY"}}{{$o}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}{{end}}')"; then
  SIGNERS="$(printf '%s\n' "$SIGNERS" | sort -u)"
  OTHERS="$(printf '%s\n' "$SIGNERS" | grep -v "^Deployment/${RELEASE}-core-api\$" | grep . || true)"
  if [ -n "$OTHERS" ]; then
    ko "JWT_PRIVATE_KEY reaches other workloads than core-api: $(echo $OTHERS)"
  else
    ok "no workload but core-api reads JWT_PRIVATE_KEY"
  fi
else
  ko "cannot list the Deployments, StatefulSets and CronJobs (RBAC of this context?)"
  SIGNERS=""
fi
if ! MANIFESTS="$($K get deploy,statefulset,cronjob -o yaml)"; then
  ko "cannot read the workload manifests (RBAC of this context?)"
elif printf '%s' "$MANIFESTS" | grep -q 'BEGIN PRIVATE KEY'; then
  ko "a PEM private key is in clear in a workload manifest (global.jwt.publicKey?)"
else
  ok "no PEM private key in clear in the workload manifests"
fi
# The shared HS256 secret is gone: a JWT_SECRET left on a workload means a
# stale manifest, or an image still verifying HS256 tokens.
if $K get deploy,statefulset -o yaml 2>/dev/null | grep -q 'name: JWT_SECRET$'; then
  ko "a workload still gets JWT_SECRET (removed by MAIR-680)"
else
  ok "no workload gets JWT_SECRET"
fi
if [ -n "$SIGNERS" ] && ! $K get deploy "${RELEASE}-core-api" -o yaml 2>/dev/null | grep -q 'name: JWT_PUBLIC_KEY'; then
  ko "core-api signs but has no JWT_PUBLIC_KEY (global.jwt.publicKey)"
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
  # MAIR-610: keycloak-test is the in-namespace label the Keycloak
  # NetworkPolicy admits for checks (besides the Keycloak-client APIs).
  if probe keycloak "app.kubernetes.io/component=keycloak-test" \
       curl -sf -m 10 "http://${RELEASE}-keycloak:8080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" \
       2>/dev/null | grep -q '"issuer":"https://'; then
    ok "realm ${KEYCLOAK_REALM} imported, issuer on https"
  else
    ko "realm ${KEYCLOAK_REALM} not served to a keycloak-test pod (import failed, or NetworkPolicy)"
  fi

  step 12b "MAIR-610: a BFF pod does not reach Keycloak (only the ingress and the Keycloak-client APIs do)"
  if probe keycloak-bff "app.kubernetes.io/component=bff" \
       curl -s -m 5 -o /dev/null "http://${RELEASE}-keycloak:8080/realms/${KEYCLOAK_REALM}/" >/dev/null 2>&1; then
    ko "a bff-labelled pod reaches Keycloak: NetworkPolicy not narrowed (MAIR-610)"
  else
    ok "bff-labelled pod refused"
  fi
else
  ok "keycloak not enabled for this instance"
fi

if [ -n "$DOMAIN" ]; then
  step 13 "Trusted TLS certificate on https://login.${DOMAIN} and https://auth.${DOMAIN}"
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

  step 13b "MAIR-414/MAIR-610: auth.${DOMAIN} serves the sign-in pages and the account console, nothing else"
  if $K get deploy "${RELEASE}-keycloak" >/dev/null 2>&1; then
    AUTH="https://auth.${DOMAIN}"
    REALM_URL="${AUTH}/realms/${KEYCLOAK_REALM}"
    # Routed: Login's sign-in page (client core-api, MAIR-153) and the
    # account console (2FA enrolment MAIR-572, settings-front link MAIR-357).
    LOGIN_CALLBACK="https%3A%2F%2Flogin.${DOMAIN}%2Fapi%2Fauth%2Fkeycloak%2Fcallback"
    SIGN_IN="${REALM_URL}/protocol/openid-connect/auth?client_id=core-api&response_type=code&scope=openid&redirect_uri=${LOGIN_CALLBACK}&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$SIGN_IN" || true)
    case "$CODE" in 200|302|303) ok "realm sign-in page served ($CODE)" ;; *) ko "realm sign-in page: code $CODE" ;; esac
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "${REALM_URL}/account/" || true)
    case "$CODE" in 200|302|303) ok "account console served ($CODE)" ;; *) ko "account console: code $CODE" ;; esac
    # Not routed: the 404 must come from the ingress controller itself, not
    # from Keycloak (which answers 404 too on /metrics or /health when they
    # reach port 8080). Traefik's body is "404 page not found", ingress-nginx's
    # carries "<center>nginx</center>"; Keycloak's is neither.
    for path in \
      "/realms/master/protocol/openid-connect/auth?client_id=security-admin-console" \
      "/realms/master/.well-known/openid-configuration" \
      "/realms/master/account/" \
      "/realms/${KEYCLOAK_REALM}/protocol/openid-connect/userinfo" \
      "/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" \
      "/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs" \
      "/admin/master/console/" \
      "/admin/realms/master" \
      "/admin/realms/${KEYCLOAK_REALM}x/users" \
      "/metrics" \
      "/health/ready"; do
      OUT=$(curl -s -m 10 -w ' %{http_code}' "${AUTH}${path}" || true)
      case "$OUT" in
        "404 page not found"*" 404"|*"<center>nginx</center>"*" 404") ok "${path%%\?*} not routed (ingress 404)" ;;
        *" 404") ko "${path%%\?*} reaches Keycloak (404 from Keycloak, not the ingress)" ;;
        *) ko "${path%%\?*} reachable from the Internet: code ${OUT##* }" ;;
      esac
    done

    # MAIR-609/MAIR-610: the realm's console, when the instance publishes it
    # (global.keycloak.consoleAccess, Traefik), sits behind core-api's
    # ForwardAuth: without the cookie of a temporary link, core-api answers
    # 401 and Keycloak is never reached. Not published: the ingress's 404.
    # A bogus link is refused by core-api itself.
    step 13c "MAIR-609/MAIR-610: the realm's admin console needs core-api's temporary access"
    for path in "/admin/${KEYCLOAK_REALM}/console/" "/admin/realms/${KEYCLOAK_REALM}/users"; do
      OUT=$(curl -s -m 10 -w ' %{http_code}' "${AUTH}${path}" || true)
      case "$OUT" in
        "404 page not found"*" 404"|*"<center>nginx</center>"*" 404") ok "${path}: console not published on this instance (ingress 404)" ;;
        *" 401") ok "${path}: refused without the console cookie (401)" ;;
        *) ko "${path}: code ${OUT##* } without the console cookie, expected 401 or the ingress 404" ;;
      esac
    done
    OUT=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "${AUTH}/admin-access?token=not-a-link" || true)
    case "$OUT" in
      401) ok "/admin-access refuses a bogus link (401)" ;;
      404) ok "/admin-access not published on this instance (404)" ;;
      *) ko "/admin-access?token=not-a-link: code ${OUT}, expected 401" ;;
    esac
  else
    ok "keycloak not enabled for this instance"
  fi

  step 14 "HTTP redirects to HTTPS"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://login.${DOMAIN}" || true)
  case "$CODE" in 301|302|308) ok "redirect $CODE" ;; *) ko "code $CODE" ;; esac

  step 15 "Only the fronts and Keycloak are exposed (6443 must be on the VPN, not public)"
  IP=$(getent hosts "login.${DOMAIN}" | awk '{print $1}' | head -1)
  for p in 3000 4000 5432 6379 6443 8080 9000; do
    if timeout 3 bash -c "</dev/tcp/${IP}/${p}" 2>/dev/null; then
      ko "port ${p} open to the Internet"
    else
      ok "port ${p} closed"
    fi
  done
fi

echo
[ $FAILED -eq 0 ] && { echo "Acceptance OK"; exit 0; } || { echo "Acceptance FAILED"; exit 1; }
