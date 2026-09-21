#!/usr/bin/env bash
# Flow matrix of the chart's NetworkPolicies. Each line: source probe,
# target Service, expected verdict. Every flow is checked (no early exit) so
# one run shows the whole picture; the script fails if any verdict differs.
#
# "allow" flows matter as much as "deny" ones: without them, a cluster where
# nothing can talk at all would pass.
set -uo pipefail

: "${NAMESPACE:?}" "${RELEASE:?}"
TIMEOUT=3

FRONT="${RELEASE}-login-front:80"
BFF="${RELEASE}-user-bff:4000"
OTHER_BFF="${RELEASE}-calendar-bff:4002"
API="${RELEASE}-core-api:3000"
DB="${RELEASE}-database:5432"
REDIS="${RELEASE}-redis:6379"

FLOWS="
ingress   $FRONT     allow
ingress   $BFF       deny
ingress   $API       deny
ingress   $DB        deny
ingress   $REDIS     deny

none      $FRONT     deny
none      $BFF       deny
none      $API       deny
none      $DB        deny
none      $REDIS     deny

frontend  $FRONT     deny
frontend  $BFF       allow
frontend  $API       deny
frontend  $DB        deny
frontend  $REDIS     deny

bff       $FRONT     deny
bff       $OTHER_BFF allow
bff       $API       allow
bff       $REDIS     allow
bff       $DB        deny

api       $FRONT     deny
api       $BFF       deny
api       $API       deny
api       $DB        allow
api       $REDIS     allow

migration $DB        allow
migration $API       deny
migration $REDIS     deny

backup    $DB        allow
backup    $API       deny
backup    $REDIS     deny
"

FAILED=0
while read -r source target expected; do
  [ -z "$source" ] && continue

  if [ "$source" = ingress ]; then
    # Cross-namespace: the Service needs its fully qualified name.
    ns=ingress-nginx
    host="${target%%:*}.${NAMESPACE}.svc.cluster.local"
  else
    ns="$NAMESPACE"
    host="${target%%:*}"
  fi
  port="${target##*:}"

  # Cilium drops denied packets silently, so a denied flow is a TIMEOUT. A
  # fast failure (connection refused, unknown host) means the target itself
  # is broken, and must not pass as a "deny".
  start=$(date +%s%N)
  if out=$(kubectl -n "$ns" exec "probe-$source" -- nc -z -w "$TIMEOUT" "$host" "$port" 2>&1); then
    actual=allow
  elif (( ($(date +%s%N) - start) / 1000000 >= (TIMEOUT * 1000) - 200 )); then
    actual=deny
  else
    actual="error (${out:-connection refused})"
  fi

  if [ "$actual" = "$expected" ]; then
    printf 'ok    %-10s -> %-26s %s\n' "$source" "$target" "$actual"
  else
    printf 'FAIL  %-10s -> %-26s expected %s, got %s\n' "$source" "$target" "$expected" "$actual"
    FAILED=1
  fi
done <<< "$FLOWS"

exit "$FAILED"
