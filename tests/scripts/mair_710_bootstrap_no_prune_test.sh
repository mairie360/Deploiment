#!/usr/bin/env bash
# MAIR-710: the root `platform` Application follows main on every group, prod
# included, so a commit on main that deletes or renames a file of
# bootstrap/appsets/ must not delete anything on the instance clusters:
#   - `platform` does not prune;
#   - every ApplicationSet of bootstrap/appsets/ keeps the add-on's resources
#     when its Application is deleted (preserveResourcesOnDeletion, and no
#     explicit resources finalizer, which would override it)...
#   - ...except the ingress controllers, whose finalizer frees ports 80/443
#     when a machine switches controller (ADR 0001).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import glob, os, sys, yaml

root = sys.argv[1]
# ApplicationSets whose Applications must delete the add-on with them.
CASCADE = {"ingress-nginx", "traefik"}
failed = False

def check(ok, label):
    global failed
    print(f"  {'OK  ' if ok else 'FAIL'}  {label}")
    failed |= not ok

platform = yaml.safe_load(open(os.path.join(root, "bootstrap/platform-app.yaml")))
auto = (platform["spec"].get("syncPolicy") or {}).get("automated") or {}
check(auto.get("prune") is False, "platform: automated.prune is false")
check(auto.get("selfHeal") is True, "platform: selfHeal kept (drift is still reverted)")

seen = set()
for path in sorted(glob.glob(os.path.join(root, "bootstrap/appsets/*.yaml"))):
    for doc in yaml.safe_load_all(open(path)):
        if not doc or doc.get("kind") != "ApplicationSet":
            continue
        name = doc["metadata"]["name"]
        seen.add(name)
        if name in CASCADE:
            continue
        preserve = (doc["spec"].get("syncPolicy") or {}).get("preserveResourcesOnDeletion")
        finalizers = doc["spec"]["template"]["metadata"].get("finalizers") or []
        check(preserve is True and not finalizers,
              f"{name}: preserveResourcesOnDeletion and no explicit finalizer")

check({"cert-manager", "cluster-issuers", "sealed-secrets"} <= seen,
      "the add-on ApplicationSets were all found")
sys.exit(1 if failed else 0)
PY
