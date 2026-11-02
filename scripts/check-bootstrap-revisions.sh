#!/usr/bin/env bash
# =============================================================================
# The bootstrap add-ons follow each machine's revision (MAIR-346).
#
#   ./scripts/check-bootstrap-revisions.sh [bootstrap-dir]   (default: bootstrap)
#
# The root `platform` Application applies bootstrap/appsets/ from `main` to
# every machine at once. A version or values written in an AppSet manifest
# would therefore reach prod on merge, skipping staging. So every
# ApplicationSet that targets instance machines (clusters generator selecting
# mairie360.fr/role=instance) must:
#
#   - use goTemplate and compute `values.revision` from the Argo CD cluster
#     annotation mairie360.fr/revision, falling back to `main`;
#   - read every source from this repository, under bootstrap/, at
#     '{{ .values.revision }}': no Helm repository (`chart:`), no fixed
#     revision, no `$values` ref to another revision.
#
# Also refuses a domain or an IP in cert-manager's AppSet and values (MAIR-157:
# shared by every group). Fails, naming the file, on the first broken rule of
# each AppSet. Needs python3 with PyYAML.
# Tests: tests/scripts/mair_346_bootstrap_revisions_test.sh
# =============================================================================
set -euo pipefail

DIR="${1:-bootstrap}"

python3 - "$DIR" <<'PY'
import glob, os, re, sys, yaml

root = sys.argv[1]
REPO = "https://github.com/mairie360/Deploiment.git"
REVISION = "{{ .values.revision }}"
ANNOTATION = "mairie360.fr/revision"
failed = False


def err(path, msg):
    global failed
    print(f"::error file={path}::{msg}")
    failed = True


def targets_instances(spec):
    for gen in spec.get("generators") or []:
        sel = (gen.get("clusters") or {}).get("selector") or {}
        if (sel.get("matchLabels") or {}).get("mairie360.fr/role") == "instance":
            return gen["clusters"]
    return None


seen = 0
for path in sorted(glob.glob(os.path.join(root, "appsets", "*.yaml"))):
    for doc in yaml.safe_load_all(open(path)):
        if not doc or doc.get("kind") != "ApplicationSet":
            continue
        spec = doc.get("spec") or {}
        clusters = targets_instances(spec)
        if clusters is None:
            continue
        seen += 1
        name = doc["metadata"]["name"]
        if spec.get("goTemplate") is not True:
            err(path, f"{name}: goTemplate must be true (the revision expression is a Go template)")
        rev = str((clusters.get("values") or {}).get("revision", ""))
        if ANNOTATION not in rev or '"main"' not in rev:
            err(path, f"{name}: values.revision must read the {ANNOTATION} cluster annotation, `main` when absent")
        tspec = (doc.get("spec") or {}).get("template", {}).get("spec", {})
        sources = list(tspec.get("sources") or [])
        if tspec.get("source"):
            sources.append(tspec["source"])
        if not sources:
            err(path, f"{name}: no source")
        for src in sources:
            if "chart" in src:
                err(path, f"{name}: source `chart: {src['chart']}` reads a Helm repository; "
                          "pin the version in bootstrap/addons/<addon>/Chart.yaml instead")
            if src.get("repoURL") != REPO:
                err(path, f"{name}: source {src.get('repoURL')} is not this repository")
            if str(src.get("targetRevision")) != REVISION:
                err(path, f"{name}: targetRevision {src.get('targetRevision')!r} "
                          f"must be '{REVISION}' (the machine's revision)")
            if not str(src.get("path", "")).startswith("bootstrap/"):
                err(path, f"{name}: path {src.get('path')!r} is outside bootstrap/")

if seen == 0:
    err(os.path.join(root, "appsets"), "no ApplicationSet targets the instance machines")

# MAIR-157: cert-manager's configuration is shared by every group.
domain_or_ip = re.compile(r"mairie360-eip|\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b")
for path in (os.path.join(root, "appsets", "cert-manager-appset.yaml"),
             os.path.join(root, "addons", "cert-manager", "values.yaml")):
    if os.path.exists(path):
        for n, line in enumerate(open(path), 1):
            if domain_or_ip.search(line):
                err(path, f"line {n}: cert-manager's AppSet and values must name no domain and no IP (MAIR-157)")

if not failed:
    print(f"OK: {seen} instance ApplicationSet(s) read bootstrap/ at the machine's revision")
sys.exit(1 if failed else 0)
PY
