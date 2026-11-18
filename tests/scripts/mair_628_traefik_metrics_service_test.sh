#!/usr/bin/env bash
# MAIR-628: Traefik serves its Prometheus metrics on a ClusterIP Service
# traefik-metrics:9100 (never public), the target the instance collector
# scrapes (charts/observability ingressMetrics.target) for the 5xx alert of
# mairie360/Infra. Renders the wrapper chart and checks that Service.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/bootstrap/addons/traefik"

if ! command -v helm >/dev/null; then
  echo "FAIL  helm is required"; exit 1
fi
"$ROOT/scripts/addon-deps.sh" "$CHART" || { echo "FAIL  scripts/addon-deps.sh"; exit 1; }
rendered="$(helm template traefik "$CHART" --namespace traefik)" || {
  echo "FAIL  helm template"; exit 1
}
target="$(sed -n 's/^  target: "\(.*\)"$/\1/p' "$ROOT/charts/mairie360-stack/charts/observability/values.yaml" | grep traefik)"

python3 - "$rendered" "$target" <<'PY'
import sys, yaml

failed = False
def check(ok, label):
    global failed
    print(f"  {'OK  ' if ok else 'FAIL'}  {label}")
    failed |= not ok

docs = [d for d in yaml.safe_load_all(sys.argv[1]) if d]
svcs = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Service"}
m = svcs.get("traefik-metrics")
check(m is not None, "a traefik-metrics Service exists")
if m:
    check(m["spec"].get("type", "ClusterIP") == "ClusterIP", "it is ClusterIP, never exposed")
    check([p["port"] for p in m["spec"]["ports"]] == [9100], "it serves port 9100 only")
check(sys.argv[2] == "traefik-metrics.traefik.svc:9100",
      f"the collector scrapes that Service (ingressMetrics.target = {sys.argv[2]!r})")
public = [p["port"] for p in svcs.get("traefik", {}).get("spec", {}).get("ports", [])]
check(9100 not in public, "the LoadBalancer Service does not publish the metrics port")
sys.exit(1 if failed else 0)
PY
