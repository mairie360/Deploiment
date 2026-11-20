#!/usr/bin/env bash
# MAIR-814: Keycloak is removed from the deployment. No instance may render a
# Keycloak resource, an `auth.` host or a Keycloak environment variable, with
# either ingress controller, and no SealedSecret may still carry its keys.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
failed=0

check() {
  if [ "$1" = 0 ]; then echo "  OK    $2"; else echo "  FAIL  $2"; failed=1; fi
}

[ ! -d charts/mairie360-stack/charts/keycloak ]
check $? "the keycloak subchart is gone"

for v in clusters/*/instances/*; do
  for c in nginx traefik; do
    mapfile -t files < <("$ROOT/scripts/instance-values.sh" "$v" --secrets)
    args=()
    for f in "${files[@]}"; do args+=(-f "$f"); done
    out=$(helm template r ./charts/mairie360-stack "${args[@]}" --set global.ingressController="$c" 2>&1)
    [ -n "$out" ] && ! grep -qi 'keycloak' <<<"$out" && ! grep -q 'host: auth\.' <<<"$out"
    check $? "$v ($c): no Keycloak resource, variable, secret or auth. host"
  done
done

! grep -rqi 'keycloak' clusters --include=secrets.yaml
check $? "no instance secrets.yaml seals a Keycloak Secret"

exit "$failed"
