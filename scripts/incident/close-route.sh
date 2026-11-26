#!/usr/bin/env bash
# Incident response (incident-response.md): close one front's public route — e.g. a front
# under active abuse — without taking the whole instance down. Applies a NetworkPolicy that denies
# every ingress to that front's pods (Cilium, the CNI, enforces it), so the ingress controller can no
# longer reach it and the host answers 502/503 for that front only. The rest keeps serving.
#
#   scripts/incident/close-route.sh login-front --context <kube> [--namespace mairie360-staging]
#   scripts/incident/close-route.sh login-front --context <kube> --remove
#
# OUT-OF-BAND: a deny NetworkPolicy is additive and holds until the next Argo CD sync prunes it on
# staging / prod (synced by hand). Reverse with --remove. Needs kubectl against the instance API.
set -euo pipefail

usage() { echo "usage: $0 <front-instance> --context CTX [--namespace NS] [--remove]" >&2; exit 2; }

FRONT="" ; CTX="" ; NS="" ; REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -*) usage ;;
    *) FRONT="$1"; shift ;;
  esac
done
[ -n "$FRONT" ] || usage
[ -n "$CTX" ] || usage
[ -n "$NS" ] || NS="mairie360-${ENV:-staging}"

NAME="incident-close-${FRONT}"
K=(kubectl --context "$CTX" -n "$NS")

if [ "$REMOVE" -eq 1 ]; then
  "${K[@]}" delete networkpolicy "$NAME" --ignore-not-found
  echo "reopened: ${FRONT} (policy ${NAME})"
  exit 0
fi

# Selects the front by its legacy `app: <instance>` label (immutable, always present) and allows no
# ingress: an empty `ingress:` with the Ingress policy type denies everything to those pods.
"${K[@]}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NAME}
  labels:
    incident-response: close-route
spec:
  podSelector:
    matchLabels:
      app: ${FRONT}
  policyTypes:
    - Ingress
  ingress: []
YAML
echo "closed: ${FRONT} answers no ingress (policy ${NAME}); reopen with --remove"
