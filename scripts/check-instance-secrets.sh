#!/usr/bin/env bash
# =============================================================================
# Check that every Secret an instance's pods need is in its secrets.yaml
# (MAIR-414).
#
#   ./scripts/check-instance-secrets.sh [--warn] [instance-dir ...]
#
# Instance dirs are relative to the repo root (default: every
# clusters/*/instances/*).
#
# Renders each instance the way Argo CD does (scripts/instance-values.sh:
# clusters/_base/<env>.yaml + values.yaml + secrets.yaml,
# release and namespace named after the environment), then compares:
#   - what the pods reference: env secretKeyRef, envFrom secretRef and secret
#     volumes, unless marked `optional: true`;
#   - what the render provides: Secrets created by the chart and the
#     SealedSecrets of secrets.yaml, whose KEY NAMES are readable in clear
#     (only the values are encrypted).
# A missing Secret or key is a pod stuck in CreateContainerConfigError once
# synced: e.g. `backup.enabled` without <env>-backup-secret, or the Liquibase
# Job without ADMIN_EMAIL / ADMIN_PASSWORD. Values cannot be checked here
# (encrypted with the instance's key): scripts/verify.sh does it on the cluster.
#
# An instance without secrets.yaml has not been sealed yet (its first sync is
# expected to fail, see CLAUDE.md): reported and skipped.
# --warn reports as GitHub warnings and always exits 0 (CI on main); without
# it, any missing Secret or key fails (the Promote workflow).
# Needs helm (with `helm dependency build` done) and python3 with PyYAML.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
CHART=./charts/mairie360-stack
WARN=0
if [ "${1:-}" = "--warn" ]; then WARN=1; shift; fi
if [ $# -gt 0 ]; then INSTANCES=("$@"); else INSTANCES=(clusters/*/instances/*); fi

FAILED=0
REPORT="$(mktemp)"; trap 'rm -f "$REPORT"' EXIT
for dir in "${INSTANCES[@]}"; do
  dir="${dir%/}"
  env_name="$(basename "$dir")"
  if [ ! -f "$dir/secrets.yaml" ]; then
    echo "SKIP $dir: no secrets.yaml (not sealed yet)"
    continue
  fi
  mapfile -t files < <(./scripts/instance-values.sh "$dir" --secrets)
  args=(); for f in "${files[@]}"; do args+=(-f "$f"); done
  if ! rendered="$(helm template "$env_name" "$CHART" --namespace "mairie360-${env_name}" \
       --skip-tests "${args[@]}" 2>&1)"; then
    echo "KO   $dir: render failed"; echo "$rendered"; FAILED=1; continue
  fi
  if ! printf '%s' "$rendered" | python3 -c '
import sys, yaml

provided, needed = {}, {}
for doc in yaml.safe_load_all(sys.stdin):
    if not isinstance(doc, dict):
        continue
    kind, meta = doc.get("kind"), doc.get("metadata") or {}
    if kind == "Secret":
        provided[meta["name"]] = set(doc.get("data") or {}) | set(doc.get("stringData") or {})
        continue
    if kind == "SealedSecret":
        spec = doc.get("spec") or {}
        name = ((spec.get("template") or {}).get("metadata") or {}).get("name") or meta["name"]
        provided[name] = set(spec.get("encryptedData") or {})
        continue
    spec = doc.get("spec") or {}
    if kind == "CronJob":
        spec = (spec.get("jobTemplate") or {}).get("spec") or {}
    pod = (spec.get("template") or {}).get("spec") if kind != "Pod" else spec
    if not pod:
        continue
    who = "%s/%s" % (kind, meta.get("name"))
    for c in (pod.get("containers") or []) + (pod.get("initContainers") or []):
        for e in c.get("env") or []:
            ref = (e.get("valueFrom") or {}).get("secretKeyRef")
            if ref and not ref.get("optional"):
                needed.setdefault((ref["name"], ref["key"]), set()).add(who)
        for e in c.get("envFrom") or []:
            ref = e.get("secretRef")
            if ref and not ref.get("optional"):
                needed.setdefault((ref["name"], None), set()).add(who)
    for v in pod.get("volumes") or []:
        ref = v.get("secret")
        if ref and not ref.get("optional"):
            needed.setdefault((ref["secretName"], None), set()).add(who)

lines = {}
for (name, key), users in needed.items():
    if name not in provided:
        lines.setdefault("missing Secret %s" % name, set()).update(users)
    elif key is not None and key not in provided[name]:
        lines.setdefault("missing key %s in %s" % (key, name), set()).update(users)
for line in sorted(lines):
    print("  %s (needed by %s)" % (line, ", ".join(sorted(lines[line]))))
sys.exit(1 if lines else 0)
' > "$REPORT" 2>&1; then
    if [ "$WARN" = 1 ]; then
      while IFS= read -r line; do echo "::warning title=$dir secrets::${line#  }"; done < "$REPORT"
    else
      echo "KO   $dir"; cat "$REPORT"
    fi
    FAILED=1
  else
    echo "OK   $dir"
  fi
done

if [ "$FAILED" = 1 ] && [ "$WARN" = 0 ]; then
  echo
  echo "Seal the missing secrets on the instance (ansible playbooks/secrets.yml, or"
  echo "scripts/seal-secrets.sh), commit secrets.yaml, then promote again."
  exit 1
fi
exit 0
