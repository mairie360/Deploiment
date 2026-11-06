#!/usr/bin/env bash
# MAIR-795: cert-manager copies an Ingress's HTTP-01 solver class onto its
# Certificate only when it CREATES it. A Certificate created before the
# annotation existed (or on another ingress controller) keeps the wrong class,
# or none, and falls back to the ClusterIssuer default (nginx): on a Traefik
# machine its challenges answer 404 forever and the renewal stalls silently
# (prod fronts 2026-11-06, prod Keycloak still pinned on nginx).
#
# scripts/verify.sh step 12c must fail, naming the Certificate and both
# classes, when a Certificate's class is not the one its Ingress asks for. The
# fake kubectl replays the cases of the ticket; the real cluster is not needed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
TAB=$'\t'

# Fake kubectl: logs every call; answers `auth can-i list ...` from $CAN, the
# two `get` calls from the fixtures; refuses everything else (the other steps
# of verify.sh fail against it, which these checks ignore). The ANSI colours of
# ok()/ko() are stripped, and only step 12c's own lines are looked at (the
# trailing "Acceptance FAILED" line of the whole script would match a bare FAIL).
cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$KUBECTL_LOG"
case "$*" in
  *"auth can-i list certificates.cert-manager.io"*|*"auth can-i list ingresses.networking.k8s.io"*)
    [ "$CAN" = yes ] && { echo yes; exit 0; }; echo no; exit 1 ;;
  *"get certificates.cert-manager.io"*) cat "$CERTS_TSV"; exit 0 ;;
  *"get ingresses.networking.k8s.io"*) cat "$INGRESS_TSV"; exit 0 ;;
esac
exit 1
SH
chmod +x "$TMP/bin/kubectl"

FAILED=0
check() { if eval "$2"; then echo "  OK    $1"; else echo "  FAIL  $1"; FAILED=1; fi; }

# run <name> <can: yes|no>: verify.sh against the fake with the fixtures
# $TMP/<name>.certs and $TMP/<name>.ingresses.
run() {
  : > "$TMP/$1.log"
  PATH="$TMP/bin:$PATH" KUBECTL_LOG="$TMP/$1.log" CAN="$2" \
    CERTS_TSV="$TMP/$1.certs" INGRESS_TSV="$TMP/$1.ingresses" \
    "$ROOT/scripts/verify.sh" fake staging 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$TMP/$1.out" || true
}
fixture() { # fixture <name> <certs lines...> -- <ingress lines...>
  local n=$1; shift; : > "$TMP/$n.certs"; : > "$TMP/$n.ingresses"
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do printf '%s\n' "$1" >> "$TMP/$n.certs"; shift; done
  shift
  while [ $# -gt 0 ]; do printf '%s\n' "$1" >> "$TMP/$n.ingresses"; shift; done
}

# 1. The fixed state of prod fronts: annotated traefik, Ingress asks traefik.
fixture ok "prod-fronts-tls${TAB}prod-fronts${TAB}traefik" -- "prod-fronts${TAB}traefik"
run ok yes
check "a Certificate on the class its Ingress asks for passes" "grep -q 'OK .*prod-fronts-tls: solver class traefik' '$TMP/ok.out'"
check "...and nothing fails in step 12c" "! sed -n '/^\[12c\]/,/^\[13/p' '$TMP/ok.out' | grep -q '^  FAIL  '"

# 2. Prod fronts before the fix: no annotation, so the ClusterIssuer default.
fixture legacy "prod-fronts-tls${TAB}prod-fronts${TAB}" -- "prod-fronts${TAB}traefik"
run legacy yes
check "a Certificate without annotation on a Traefik Ingress fails" "grep -q 'FAIL .*prod-fronts-tls' '$TMP/legacy.out'"
check "...naming both classes and where the wrong one comes from" \
  "grep 'FAIL .*prod-fronts-tls' '$TMP/legacy.out' | grep -q \"'nginx' (default) but Ingress prod-fronts asks for 'traefik'\""
check "...with the command that recreates it" "grep -q 'delete certificate prod-fronts-tls' '$TMP/legacy.out'"

# 3. Prod Keycloak: an explicit nginx override copied while the machine was on nginx.
fixture pinned "prod-keycloak-tls${TAB}prod-keycloak${TAB}nginx" -- "prod-keycloak${TAB}traefik"
run pinned yes
check "an explicit nginx override on a Traefik Ingress fails" \
  "grep 'FAIL .*prod-keycloak-tls' '$TMP/pinned.out' | grep -q \"'nginx' (annotation) but Ingress prod-keycloak asks for 'traefik'\""

# 4. A nginx machine whose Certificate predates the annotation still works:
#    no annotation = the ClusterIssuer default = nginx = what its Ingress asks for.
fixture nginx "dev-fronts-tls${TAB}dev-fronts${TAB}" -- "dev-fronts${TAB}nginx"
run nginx yes
check "no annotation passes on a nginx Ingress (the ClusterIssuer default)" "grep -q 'OK .*dev-fronts-tls' '$TMP/nginx.out'"

# 5. Mixed: one good, one bad; the good one must not hide the bad one.
fixture mixed "a-tls${TAB}a${TAB}traefik" "b-tls${TAB}b${TAB}nginx" -- "a${TAB}traefik" "b${TAB}traefik"
run mixed yes
check "one wrong Certificate fails even next to a good one" \
  "grep -q 'OK .*a-tls' '$TMP/mixed.out' && grep -q 'FAIL .*b-tls' '$TMP/mixed.out'"

# 6. A Certificate nothing owns, or whose Ingress is gone, is reported, not failed.
fixture orphan "hand-made-tls${TAB}${TAB}" "gone-tls${TAB}gone${TAB}nginx" -- "other${TAB}traefik"
run orphan yes
check "a hand-made Certificate and one without Ingress are skipped" \
  "! sed -n '/^\[12c\]/,/^\[13/p' '$TMP/orphan.out' | grep -q '^  FAIL  ' && grep -q 'hand-made-tls: not compared' '$TMP/orphan.out' && grep -q 'gone-tls: not compared' '$TMP/orphan.out'"

# 7. The runner's ServiceAccount may not read them (until ansible grants it).
fixture denied "x-tls${TAB}x${TAB}nginx" -- "x${TAB}traefik"
run denied no
check "without the permission the step is skipped, not failed" \
  "grep -q 'solver classes not compared' '$TMP/denied.out' && ! sed -n '/^\[12c\]/,/^\[13/p' '$TMP/denied.out' | grep -q '^  FAIL  '"
check "...and no Certificate or Ingress was read" "! grep -qE '(^| )get (certificates|ingresses)' '$TMP/denied.log'"

# 8. The default the check assumes is the one the ClusterIssuers really have.
# shellcheck source=scripts/lib/cert-solvers.sh
. "$ROOT/scripts/lib/cert-solvers.sh"
ISSUER_CLASSES=$(grep -E '^[[:space:]]+ingressClassName:' "$ROOT/bootstrap/cluster-addons/cluster-issuers.yaml" | awk '{print $2}' | sort -u)
check "CLUSTER_ISSUER_DEFAULT_SOLVER equals the ClusterIssuers' solver class (${ISSUER_CLASSES:-none})" \
  "[ '$ISSUER_CLASSES' = '$CLUSTER_ISSUER_DEFAULT_SOLVER' ]"

exit "$FAILED"
