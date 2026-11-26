#!/usr/bin/env bash
# Incident response (incident-response.md): block a hostile address at the edge of an
# instance. Applies a CiliumClusterwideNetworkPolicy that denies ingress from the given CIDR to the
# ingress controller pods; Cilium (the CNI of the k3s machines) enforces it at once.
#
#   scripts/incident/block-ip.sh 203.0.113.7 --context <kube> [--selector app.kubernetes.io/name=traefik]
#   scripts/incident/block-ip.sh 203.0.113.0/24 --context <kube> --remove
#
# OUT-OF-BAND emergency action: on staging / prod (synced by hand) it holds until the next Argo CD
# sync, then land it in git or lift it. Reverse with --remove. A bare IPv4/IPv6 becomes a /32 or
# /128. Needs kubectl against the instance's API server (like scripts/verify.sh).
set -euo pipefail

usage() { echo "usage: $0 <cidr|ip> [--context CTX] [--selector k=v] [--remove]" >&2; exit 2; }

CIDR="" ; CTX="" ; SELECTOR="app.kubernetes.io/name=traefik" ; REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    --selector) SELECTOR="$2"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) CIDR="$1"; shift ;;
  esac
done
[ -n "$CIDR" ] || usage
case "$CIDR" in
  */*) : ;;
  *:*) CIDR="$CIDR/128" ;;
  *) CIDR="$CIDR/32" ;;
esac

NAME="incident-block-$(printf '%s' "$CIDR" | tr './:' '-')"
SEL_KEY="${SELECTOR%%=*}"
SEL_VAL="${SELECTOR#*=}"
K=(kubectl)
[ -n "$CTX" ] && K+=(--context "$CTX")

if [ "$REMOVE" -eq 1 ]; then
  "${K[@]}" delete ciliumclusterwidenetworkpolicy "$NAME" --ignore-not-found
  echo "lifted: $NAME ($CIDR)"
  exit 0
fi

"${K[@]}" apply -f - <<YAML
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: ${NAME}
  labels:
    incident-response: block-ip
spec:
  endpointSelector:
    matchLabels:
      ${SEL_KEY}: ${SEL_VAL}
  enableDefaultDeny:
    ingress: false
    egress: false
  ingressDeny:
    - fromCIDR:
        - ${CIDR}
YAML
echo "blocking ${CIDR} to ${SELECTOR} pods (policy ${NAME}); lift with --remove"
