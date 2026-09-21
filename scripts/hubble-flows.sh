#!/usr/bin/env bash
# =============================================================================
# Network traffic of a deployed instance, hop by hop, as recorded by Hubble.
#
#   ./scripts/hubble-flows.sh <kube-context> <env> [flows-per-hop]
#
# Needs the `hubble` CLI (https://github.com/cilium/hubble/releases) and a
# kube context on the instance (its API server is only reachable through the
# WireGuard tunnel). Opens a port-forward to hubble-relay for the duration of
# the script. Cilium + Hubble are installed by the Ansible role k8s_node.
#
# Printed for the namespace mairie360-<env>:
#   1. dropped flows: what the NetworkPolicies refused. Apart from the probes
#      of scripts/verify.sh, this list should be empty.
#   2. each hop of the architecture with its last flows:
#        ingress -> fronts -> bffs -> apis -> postgres / redis
#   3. HTTP requests with method, path and status code (needs
#      global.networkPolicy.ciliumL7Visibility in the instance values).
#   4. flows leaving the cluster.
# =============================================================================
set -uo pipefail

CTX="${1:?usage: $0 <kube-context> <env> [flows-per-hop]}"
ENV="${2:?}"
LAST="${3:-20}"
NS="mairie360-${ENV}"
PORT="${HUBBLE_PORT:-4245}"
C="app.kubernetes.io/component"

command -v hubble >/dev/null 2>&1 \
  || { echo "hubble CLI not found: https://github.com/cilium/hubble/releases" >&2; exit 2; }

kubectl --context "$CTX" -n kube-system port-forward svc/hubble-relay "${PORT}:80" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null' EXIT

H="hubble --server localhost:${PORT}"
for _ in $(seq 1 20); do
  $H status >/dev/null 2>&1 && break
  sleep 0.5
done
$H status >/dev/null 2>&1 \
  || { echo "hubble-relay unreachable through the port-forward (is Cilium installed on ${CTX}?)" >&2; exit 1; }

OBS="$H observe --last ${LAST}"
title() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

title "Dropped flows in ${NS} (what the NetworkPolicies refused)"
$OBS --namespace "$NS" --verdict DROPPED

title "ingress-nginx -> fronts"
$OBS --from-namespace ingress-nginx --to-namespace "$NS" --to-label "${C}=frontend"

title "fronts -> bffs"
$OBS --from-label "${C}=frontend" --to-namespace "$NS" --to-label "${C}=bff"

title "bffs -> bffs (session resolution through user-bff)"
$OBS --from-label "${C}=bff" --to-namespace "$NS" --to-label "${C}=bff"

title "bffs -> apis"
$OBS --from-label "${C}=bff" --to-namespace "$NS" --to-label "${C}=api"

title "apis -> postgres"
$OBS --from-label "${C}=api" --to-namespace "$NS" --to-label "${C}=database"

title "liquibase -> postgres"
$OBS --from-label "${C}=migration" --to-namespace "$NS" --to-label "${C}=database"

title "apis / bffs -> redis"
$OBS --to-namespace "$NS" --to-label "${C}=cache"

title "HTTP requests (needs global.networkPolicy.ciliumL7Visibility)"
$OBS --namespace "$NS" --protocol http

title "Flows leaving the cluster from ${NS}"
$OBS --from-namespace "$NS" --to-label reserved:world
