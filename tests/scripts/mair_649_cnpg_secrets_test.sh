#!/usr/bin/env bash
# MAIR-649: scripts/check-instance-secrets.sh (blocking in Promote) also sees the
# Secrets a CloudNativePG Cluster and its ObjectStore read: an instance switched
# to database.cnpg without <release>-database-superuser sealed is refused, and
# accepted once it is.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/charts/mairie360-stack"
command -v helm >/dev/null || { echo "FAIL  helm is required"; exit 1; }
ls "$CHART"/charts/*.tgz >/dev/null 2>&1 || helm dependency build "$CHART" >/dev/null

ORG="zz-mair-649-test-$$"
DIR="$ROOT/clusters/$ORG/instances/dev"
trap 'rm -rf "$ROOT/clusters/$ORG"' EXIT
mkdir -p "$DIR"

# dev's values with CloudNativePG on, and dev's sealed secrets (no superuser yet).
python3 - "$ROOT/clusters/mairie360/instances/dev/values.yaml" "$DIR/values.yaml" <<'EOF'
import sys, yaml
values = yaml.safe_load(open(sys.argv[1]))
db = values.setdefault("database", {})
db["engine"] = "cnpg"
db["cnpg"] = {"enabled": True, "backup": {"s3": {"endpoint": "https://s3.fr-par.scw.cloud", "bucket": "mairie360-backups-dev"}}}
yaml.safe_dump(values, open(sys.argv[2], "w"), sort_keys=False)
EOF
cp "$ROOT/clusters/mairie360/instances/dev/secrets.yaml" "$DIR/secrets.yaml"

failed=0
out="$("$ROOT/scripts/check-instance-secrets.sh" "clusters/$ORG/instances/dev" 2>&1)"
if [ $? -eq 0 ]; then
  echo "  FAIL  a CloudNativePG instance without its superuser Secret passed:"; echo "$out"; failed=1
elif ! grep -q "missing Secret dev-database-superuser (needed by Cluster/dev-database-g1)" <<<"$out"; then
  echo "  FAIL  the refusal does not name the superuser Secret:"; echo "$out"; failed=1
else
  echo "  OK    refused without dev-database-superuser"
fi

# Once sealed (key names are what the check reads), the same instance passes.
cat >> "$DIR/secrets.yaml" <<'EOF'
  - |
    apiVersion: bitnami.com/v1alpha1
    kind: SealedSecret
    metadata:
      name: dev-database-superuser
      namespace: mairie360-dev
    spec:
      encryptedData:
        username: AgB-test-only
        password: AgB-test-only
      template:
        metadata:
          name: dev-database-superuser
          namespace: mairie360-dev
        type: kubernetes.io/basic-auth
EOF
if out="$("$ROOT/scripts/check-instance-secrets.sh" "clusters/$ORG/instances/dev" 2>&1)"; then
  echo "  OK    accepted with dev-database-superuser sealed"
else
  echo "  FAIL  still refused with the superuser Secret sealed:"; echo "$out"; failed=1
fi
exit "$failed"
