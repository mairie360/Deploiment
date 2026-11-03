#!/usr/bin/env bash
# =============================================================================
# Recette d'un environnement déployé.
#
#   ./scripts/verify.sh <contexte-kube> <env> [domaine]
#
# Sort en erreur à la première vérification qui échoue : utilisable tel quel
# en étape de CI ou en fin de playbook Ansible.
# =============================================================================
set -uo pipefail

# shellcheck source=scripts/lib/secret-values.sh
. "$(dirname "$0")/lib/secret-values.sh"

CTX="${1:?usage: $0 <contexte-kube> <env> [domaine]}"
ENV="${2:?}"
DOMAIN="${3:-}"
# Realm provisioned by charts/keycloak (global.keycloak.realm).
KEYCLOAK_REALM="${KEYCLOAK_REALM:-mairie360}"
# Une machine = un cluster = un namespace mairie360-<env>.
NS="mairie360-${ENV}"
RELEASE="${ENV}"
K="kubectl --context ${CTX} -n ${NS}"
FAILED=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
ko()   { printf '  \033[31mECHEC\033[0m %s\n' "$1"; FAILED=1; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }

step 1 "Tous les pods sont Running ou Completed"
BAD=$($K get pods --no-headers 2>/dev/null | grep -vE 'Running|Completed' || true)
[ -z "$BAD" ] && ok "aucun pod en erreur" || { ko "pods anormaux"; echo "$BAD"; }

step 2 "Aucun redémarrage en boucle"
LOOP=$($K get pods --no-headers 2>/dev/null | awk '$4 > 5 {print $1, $4}' || true)
[ -z "$LOOP" ] && ok "aucun CrashLoop" || { ko "redémarrages répétés"; echo "$LOOP"; }

step 3 "Les Services ont des endpoints (sélecteurs corrects)"
EMPTY=""
for svc in $($K get svc -o name 2>/dev/null | cut -d/ -f2); do
  case "$svc" in *-hl) continue;; esac
  EP=$($K get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  [ -z "$EP" ] && EMPTY="$EMPTY $svc"
done
[ -z "$EMPTY" ] && ok "tous les Services pointent sur des pods" || ko "Services sans endpoint :$EMPTY"

step 4 "Les secrets attendus existent"
for s in "${RELEASE}-app-secrets" "${RELEASE}-database-secret" "${RELEASE}-redis" "${RELEASE}-keycloak-secret"; do
  $K get secret "$s" >/dev/null 2>&1 && ok "$s" || ko "$s absent (scripts/seal-secrets.sh ?)"
done

if [ -n "$($K get secret "${RELEASE}-app-secrets" -o jsonpath='{.data.SMTP_PASSWORD}' 2>/dev/null)" ]; then
  ok "SMTP_PASSWORD (Resend API key) is set"
else
  ko "SMTP_PASSWORD empty in ${RELEASE}-app-secrets: core-api cannot send e-mails (RESEND_API_KEY=… scripts/seal-secrets.sh)"
fi
for k in S3_ACCESS_KEY S3_SECRET_KEY; do
  if [ -n "$($K get secret "${RELEASE}-app-secrets" -o jsonpath="{.data.$k}" 2>/dev/null)" ]; then
    ok "$k is set"
  else
    ko "$k empty in ${RELEASE}-app-secrets: elearning-api cannot start (S3_ACCESS_KEY=… S3_SECRET_KEY=… scripts/seal-secrets.sh)"
  fi
done

if [ -n "$($K get secret "${RELEASE}-database-secret" -o jsonpath="{.data.ADMIN_EMAIL}" 2>/dev/null)" ]; then
  ok "ADMIN_EMAIL is set"
else
  ko "ADMIN_EMAIL empty in ${RELEASE}-database-secret: the Liquibase Job refuses to migrate (MAIR-414, ADMIN_EMAIL=… scripts/seal-secrets.sh)"
fi
case "$($K get secret "${RELEASE}-database-secret" -o jsonpath="{.data.ADMIN_PASSWORD}" 2>/dev/null | base64 -d 2>/dev/null)" in
  '$argon2id$'*) ok "ADMIN_PASSWORD is an argon2id hash" ;;
  *) ko "ADMIN_PASSWORD in ${RELEASE}-database-secret is empty or plaintext: the Liquibase Job refuses to migrate (MAIR-414, re-run scripts/seal-secrets.sh)" ;;
esac

if [ -n "$($K get secret "${RELEASE}-keycloak-secret" -o jsonpath='{.data.CORE_API_CLIENT_SECRET}' 2>/dev/null)" ]; then
  ok "CORE_API_CLIENT_SECRET is set (MAIR-554)"
else
  ko "CORE_API_CLIENT_SECRET missing from ${RELEASE}-keycloak-secret: core-api cannot administer the realm (MAIR-554, scripts/seal-secrets.sh then scripts/keycloak-core-api-client.sh)"
fi

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

step 5 "Aucun secret en clair dans les manifestes déployés"
if $K get deploy -o yaml 2>/dev/null | grep -q 'value: .b"secret"'; then
  ko "JWT_SECRET en clair détecté"
else
  ok "aucune valeur de secret en clair"
fi

step 5b "MAIR-680: core-api alone gets the session signing key (JWT_PRIVATE_KEY)"
# Every Deployment / StatefulSet / CronJob container (and init container)
# that reads JWT_PRIVATE_KEY, as "<kind>/<name>"; only <env>-core-api may.
# A CronJob's pod template sits under spec.jobTemplate.spec.template.
SIGNERS="$($K get deploy,statefulset,cronjob -o go-template='{{range .items}}{{$o := printf "%s/%s" .kind .metadata.name}}{{$t := .spec.template}}{{with .spec.jobTemplate}}{{$t = .spec.template}}{{end}}{{with $t}}{{range .spec.containers}}{{range .env}}{{if eq .name "JWT_PRIVATE_KEY"}}{{$o}}{{"\n"}}{{end}}{{end}}{{end}}{{range .spec.initContainers}}{{range .env}}{{if eq .name "JWT_PRIVATE_KEY"}}{{$o}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}{{end}}' 2>/dev/null | sort -u)"
OTHERS="$(printf '%s\n' "$SIGNERS" | grep -v "^Deployment/${RELEASE}-core-api\$" | grep . || true)"
if [ -n "$OTHERS" ]; then
  ko "JWT_PRIVATE_KEY reaches other workloads than core-api: $(echo $OTHERS)"
else
  ok "no workload but core-api reads JWT_PRIVATE_KEY"
fi
if $K get deploy,statefulset,cronjob,configmap -o yaml 2>/dev/null | grep -q 'BEGIN PRIVATE KEY'; then
  ko "a PEM private key is in clear in a manifest or ConfigMap (global.jwt.publicKey?)"
else
  ok "no PEM private key in clear in the manifests"
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

step 6 "Redis exige un mot de passe"
POD=$($K get pod -l app=redis -o name 2>/dev/null | head -1)
if [ -n "$POD" ]; then
  if $K exec "$POD" -c redis -- redis-cli ping 2>&1 | grep -q PONG; then
    ko "Redis répond SANS mot de passe"
  else
    ok "Redis refuse les connexions non authentifiées"
  fi
else
  ko "pod redis introuvable"
fi

step 7 "La migration Liquibase a réussi"
if $K get job "${RELEASE}-liquibase" >/dev/null 2>&1; then
  S=$($K get job "${RELEASE}-liquibase" -o jsonpath='{.status.succeeded}')
  [ "${S:-0}" -ge 1 ] && ok "job terminé" || ko "job non terminé"
else
  ok "job déjà nettoyé (hook supprimé après succès)"
fi

step 8 "Cloisonnement réseau : une API n'est PAS joignable sans le label bff"
if $K run np-probe-deny --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
     --timeout=60s -- curl -s -m 5 "http://${RELEASE}-core-api:3000/health" >/dev/null 2>&1; then
  ko "un pod quelconque atteint core-api — NetworkPolicy inopérante"
else
  ok "trafic non autorisé bloqué"
fi

step 9 "Cloisonnement réseau : un pod étiqueté bff atteint l'API"
if $K run np-probe-allow --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
     --labels="app.kubernetes.io/component=bff" --timeout=60s \
     -- curl -sf -m 5 "http://${RELEASE}-core-api:3000/health" >/dev/null 2>&1; then
  ok "trafic autorisé accepté"
else
  ko "un pod bff n'atteint pas core-api (policy trop stricte ou API KO)"
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
  if $K run kc-probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
       --labels="app.kubernetes.io/component=keycloak-test" --timeout=60s \
       -- curl -sf -m 10 "http://${RELEASE}-keycloak:8080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" \
       2>/dev/null | grep -q '"issuer":"https://'; then
    ok "realm ${KEYCLOAK_REALM} imported, issuer on https"
  else
    ko "realm ${KEYCLOAK_REALM} not served to a keycloak-test pod (import failed, or NetworkPolicy)"
  fi

  step 12b "MAIR-610: a BFF pod does not reach Keycloak (only the ingress and the Keycloak-client APIs do)"
  if $K run kc-probe-bff --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
       --labels="app.kubernetes.io/component=bff" --timeout=60s \
       -- curl -s -m 5 -o /dev/null "http://${RELEASE}-keycloak:8080/realms/${KEYCLOAK_REALM}/" >/dev/null 2>&1; then
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
    case "$ISSUER" in
      *"Let's Encrypt"*) ok "${host}: issued by Let's Encrypt" ;;
      *STAGING*|*"(STAGING)"*) ko "${host}: Let's Encrypt STAGING certificate (not trusted by browsers)" ;;
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
      "/metrics" \
      "/health/ready"; do
      OUT=$(curl -s -m 10 -w ' %{http_code}' "${AUTH}${path}" || true)
      case "$OUT" in
        "404 page not found"*" 404"|*"<center>nginx</center>"*" 404") ok "${path%%\?*} not routed (ingress 404)" ;;
        *" 404") ko "${path%%\?*} reaches Keycloak (404 from Keycloak, not the ingress)" ;;
        *) ko "${path%%\?*} reachable from the Internet: code ${OUT##* }" ;;
      esac
    done
  else
    ok "keycloak not enabled for this instance"
  fi

  step 14 "Le HTTP redirige vers le HTTPS"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://login.${DOMAIN}" || true)
  case "$CODE" in 301|302|308) ok "redirection $CODE" ;; *) ko "code $CODE" ;; esac

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
[ $FAILED -eq 0 ] && { echo "Recette OK"; exit 0; } || { echo "Recette EN ECHEC"; exit 1; }
