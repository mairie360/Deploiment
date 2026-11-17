#!/usr/bin/env bash
# MAIR-617: the sealed-secrets controller of every instance must not renew its
# sealing key on its own. Each key is backed up as a version of the vault secret
# /<org>/<env>/sealing-keys, capped at 20 versions by Scaleway Secret Manager,
# and the chart default (30 days) would fill it in under two years.
# Renders the wrapper chart and checks the controller's arguments.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/bootstrap/addons/sealed-secrets"

if ! command -v helm >/dev/null; then
  echo "FAIL  helm is required"; exit 1
fi
"$ROOT/scripts/addon-deps.sh" "$CHART" || { echo "FAIL  scripts/addon-deps.sh"; exit 1; }
rendered="$(helm template sealed-secrets "$CHART" --namespace kube-system)" || {
  echo "FAIL  helm template"; exit 1
}

python3 - "$rendered" <<'PY'
import sys, yaml

failed = False
def check(ok, label):
    global failed
    print(f"  {'OK  ' if ok else 'FAIL'}  {label}")
    failed |= not ok

docs = [d for d in yaml.safe_load_all(sys.argv[1]) if d]
deploys = [d for d in docs if d.get("kind") == "Deployment"
           and d["metadata"]["name"] == "sealed-secrets-controller"]
check(len(deploys) == 1, "one sealed-secrets-controller Deployment")
args = deploys[0]["spec"]["template"]["spec"]["containers"][0].get("args", []) if deploys else []
i = args.index("--key-renew-period") if "--key-renew-period" in args else -1
check(i >= 0, "controller gets --key-renew-period")
check(i >= 0 and i + 1 < len(args) and args[i + 1] == "0",
      f"key renewal disabled (value {args[i + 1] if 0 <= i < len(args) - 1 else None!r}, want '0')")
sys.exit(1 if failed else 0)
PY
