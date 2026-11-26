#!/usr/bin/env bash
# Incident response (incident-response.md): put an instance into maintenance by scaling
# every front down to 0, so the public surface stops answering while the attack is handled. `off`
# scales them back to one replica and reminds you to re-sync Argo CD, which restores the real
# replica counts from git.
#
#   scripts/incident/maintenance.sh on  --context <kube> [--namespace mairie360-staging]
#   scripts/incident/maintenance.sh off --context <kube> [--namespace mairie360-staging]
#
# OUT-OF-BAND: Argo CD (synced by hand on staging / prod) will self-heal the replicas on the next
# sync — that is how `off` is finished. Fronts only: the APIs/BFFs keep running so an admin can still
# reach them in-cluster. Needs kubectl against the instance's API server.
set -euo pipefail

usage() { echo "usage: $0 <on|off> --context CTX [--namespace NS]" >&2; exit 2; }

MODE="${1:-}"; shift || true
CTX="" ; NS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$MODE" in on|off) : ;; *) usage ;; esac
[ -n "$CTX" ] || usage
[ -n "$NS" ] || NS="mairie360-${ENV:-staging}"

K=(kubectl --context "$CTX" -n "$NS")
SELECTOR="app.kubernetes.io/component=frontend"

if [ "$MODE" = "on" ]; then
  "${K[@]}" scale deployment -l "$SELECTOR" --replicas=0
  echo "maintenance ON: every front scaled to 0 in ${NS}. Lift with '$0 off' then re-sync Argo CD."
else
  "${K[@]}" scale deployment -l "$SELECTOR" --replicas=1
  echo "maintenance OFF: fronts scaled to 1 in ${NS}. Re-sync the Argo CD Application to restore the real replica counts from git."
fi
