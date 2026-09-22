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

CTX="${1:?usage: $0 <contexte-kube> <env> [domaine]}"
ENV="${2:?}"
DOMAIN="${3:-}"
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
for s in "${RELEASE}-app-secrets" "${RELEASE}-database-secret" "${RELEASE}-redis"; do
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

for k in ADMIN_EMAIL ADMIN_PASSWORD; do
  if [ -n "$($K get secret "${RELEASE}-database-secret" -o jsonpath="{.data.$k}" 2>/dev/null)" ]; then
    ok "$k is set"
  else
    ko "$k empty in ${RELEASE}-database-secret: admin account stays on its changelog template credentials (MAIR-170, ADMIN_EMAIL=… scripts/seal-secrets.sh)"
  fi
done

step 5 "Aucun secret en clair dans les manifestes déployés"
if $K get deploy -o yaml 2>/dev/null | grep -q 'value: .b"secret"'; then
  ko "JWT_SECRET en clair détecté"
else
  ok "aucune valeur de secret en clair"
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

step 11 "MAIR-119: the latest backup Job succeeded"
if $K get cronjob "${RELEASE}-backup" >/dev/null 2>&1; then
  LATEST=$($K get jobs -l app.kubernetes.io/component=backup \
             --sort-by=.status.startTime -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
  if [ -z "$LATEST" ]; then
    ok "backup CronJob present, no Job has run yet"
  else
    S=$($K get job "$LATEST" -o jsonpath='{.status.succeeded}' 2>/dev/null)
    [ "${S:-0}" -ge 1 ] && ok "backup $LATEST succeeded" || ko "backup $LATEST failed or still running"
  fi
else
  ok "backup not enabled for this instance"
fi

if [ -n "$DOMAIN" ]; then
  step 12 "Certificat TLS vérifié sur https://login.${DOMAIN}"
  ISSUER=$(echo | openssl s_client -connect "login.${DOMAIN}:443" \
             -servername "login.${DOMAIN}" 2>/dev/null \
           | openssl x509 -noout -issuer 2>/dev/null || true)
  case "$ISSUER" in
    *"Let's Encrypt"*) ok "émis par Let's Encrypt" ;;
    *STAGING*|*"(STAGING)"*) ko "certificat Let's Encrypt STAGING (non vérifié par les navigateurs)" ;;
    *) ko "certificat inattendu : ${ISSUER:-aucun}" ;;
  esac

  step 13 "Le HTTP redirige vers le HTTPS"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://login.${DOMAIN}" || true)
  case "$CODE" in 301|302|308) ok "redirection $CODE" ;; *) ko "code $CODE" ;; esac

  step 14 "Seuls les fronts sont exposés (6443 doit être sur le VPN, pas public)"
  IP=$(getent hosts "login.${DOMAIN}" | awk '{print $1}' | head -1)
  for p in 3000 4000 5432 6379 6443; do
    if timeout 3 bash -c "</dev/tcp/${IP}/${p}" 2>/dev/null; then
      ko "port ${p} ouvert sur Internet"
    else
      ok "port ${p} fermé"
    fi
  done
fi

echo
[ $FAILED -eq 0 ] && { echo "Recette OK"; exit 0; } || { echo "Recette EN ECHEC"; exit 1; }
