#!/usr/bin/env bash
# MAIR-620: every mairie360 instance declares its observability switch and its
# Cockpit endpoints, and every instance with global.observability.enabled
# points at real Cockpit data sources: the OTLP URLs mairie360/Infra outputs
# (orgs/<org> output instances.<env>.cockpit_endpoints), never a placeholder.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib, re, subprocess, sys, yaml

root = pathlib.Path(sys.argv[1])
failed = False
def check(ok, label):
    global failed
    print(f"  {'OK  ' if ok else 'FAIL'}  {label}")
    failed |= not ok

def merged(instance):
    files = subprocess.run([root / "scripts/instance-values.sh", instance], capture_output=True, text=True,
                           check=True).stdout.split()
    out = {}
    def merge(a, b):
        for k, v in b.items():
            a[k] = merge(a.get(k, {}), v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
        return a
    for f in files:
        merge(out, yaml.safe_load(pathlib.Path(f).read_text()) or {})
    return out

for env in ("dev", "staging", "prod"):
    v = merged(root / f"clusters/mairie360/instances/{env}")
    obs = (v.get("global") or {}).get("observability") or {}
    check("enabled" in obs and "cockpit" in (v.get("observability") or {}),
          f"mairie360/{env}: observability switch and Cockpit endpoints declared")

for instance in sorted((root / "clusters").glob("*/instances/*")):
    v = merged(instance)
    if not ((v.get("global") or {}).get("observability") or {}).get("enabled"):
        continue
    cockpit = (v.get("observability") or {}).get("cockpit") or {}
    for kind in ("metrics", "traces"):
        url = cockpit.get(f"{kind}Endpoint", "")
        pattern = rf"https://[0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}}\.{kind}\.cockpit\.fr-par\.scw\.cloud/otlp/v1/{kind}"
        check(re.fullmatch(pattern, url or "") is not None,
              f"{instance.relative_to(root)}: {kind}Endpoint {url!r} is a Cockpit {kind} data source")
sys.exit(1 if failed else 0)
PY
