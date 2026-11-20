#!/usr/bin/env bash
# MAIR-649: every instance machine gets the CloudNativePG operator (database.cnpg
# needs it), from the wrapper chart at the machine's revision, in cnpg-system,
# and the mairie360-platform AppProject admits that namespace (and the chart
# repository the wrapper's Chart.lock resolves from), or Argo CD refuses it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import sys, yaml
root = sys.argv[1]
failed = []
def check(ok, msg):
    print(("  OK    " if ok else "  FAIL  ") + msg)
    if not ok:
        failed.append(msg)

appset = yaml.safe_load(open(root + "/bootstrap/appsets/cloudnative-pg-appset.yaml"))
spec = appset["spec"]
gen = spec["generators"][0]["clusters"]
tpl = spec["template"]["spec"]
check(gen["selector"]["matchLabels"] == {"mairie360.fr/role": "instance"}, "instances only")
check(tpl["source"]["path"] == "bootstrap/addons/cloudnative-pg", "reads the wrapper chart")
check(tpl["source"]["targetRevision"] == "{{ .values.revision }}", "at the machine's revision")
check(tpl["destination"]["namespace"] == "cnpg-system", "namespace cnpg-system")
check("ServerSideApply=true" in tpl["syncPolicy"]["syncOptions"], "server-side apply (CRDs too large for client-side)")
check(tpl["project"] == "mairie360-platform", "project mairie360-platform")

chart = yaml.safe_load(open(root + "/bootstrap/addons/cloudnative-pg/Chart.yaml"))
repos = {d["repository"] for d in chart["dependencies"]}
names = {d["name"] for d in chart["dependencies"]}
check(names == {"cloudnative-pg", "plugin-barman-cloud"}, "operator and Barman Cloud plugin")

project = next(d for d in yaml.safe_load_all(open(root + "/bootstrap/appsets/projects.yaml"))
               if d and d["metadata"]["name"] == "mairie360-platform")
check(repos <= set(project["spec"]["sourceRepos"]), "AppProject admits the chart repository")
check(any(d.get("namespace") == "cnpg-system" for d in project["spec"]["destinations"]),
      "AppProject admits cnpg-system")
sys.exit(1 if failed else 0)
PY
