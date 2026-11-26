#!/usr/bin/env bash
# MAIR-1194: the incident-response cut helpers must emit the right kubectl action. A fake kubectl
# records what it is asked to apply / scale / delete; no cluster is needed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INC="$ROOT/scripts/incident"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
FAILED=0
ok()  { echo "  OK   $1"; }
ko()  { echo "  FAIL $1"; FAILED=1; }
has() { if grep -q -- "$2" "$1"; then ok "$3"; else ko "$3 (missing '$2')"; echo "--- $1"; cat "$1"; fi; }

# Fake kubectl: append the whole argv (and any stdin for `apply -f -`) to $LOG.
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGS: $*"; if printf '%s ' "$@" | grep -q -- '-f -'; then echo "STDIN:"; cat; fi; } >> "$KLOG"
EOF
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"

# --- block-ip: a single IP becomes /32 and a CiliumClusterwideNetworkPolicy ingressDeny is applied.
export KLOG="$TMP/block.log"; : > "$KLOG"
"$INC/block-ip.sh" 203.0.113.7 --context c >/dev/null 2>&1
has "$KLOG" "kind: CiliumClusterwideNetworkPolicy" "block-ip applies a Cilium clusterwide policy"
has "$KLOG" "203.0.113.7/32" "block-ip turns a bare IP into a /32"
has "$KLOG" "ingressDeny" "block-ip denies ingress"

# --- block-ip --remove deletes the named policy.
export KLOG="$TMP/block-rm.log"; : > "$KLOG"
"$INC/block-ip.sh" 203.0.113.7 --context c --remove >/dev/null 2>&1
has "$KLOG" "delete ciliumclusterwidenetworkpolicy incident-block-203-0-113-7-32" "block-ip --remove deletes its policy"

# --- maintenance on: fronts scaled to 0.
export KLOG="$TMP/maint-on.log"; : > "$KLOG"
"$INC/maintenance.sh" on --context c --namespace mairie360-staging >/dev/null 2>&1
has "$KLOG" "scale deployment -l app.kubernetes.io/component=frontend --replicas=0" "maintenance on scales fronts to 0"
grep -q "mairie360-staging" "$KLOG" && ok "maintenance targets the given namespace" || ko "maintenance namespace"

# --- maintenance off: fronts scaled back.
export KLOG="$TMP/maint-off.log"; : > "$KLOG"
"$INC/maintenance.sh" off --context c --namespace mairie360-staging >/dev/null 2>&1
has "$KLOG" "replicas=1" "maintenance off scales fronts back"

# --- close-route: a deny NetworkPolicy on the front's app label.
export KLOG="$TMP/close.log"; : > "$KLOG"
"$INC/close-route.sh" login-front --context c --namespace mairie360-staging >/dev/null 2>&1
has "$KLOG" "kind: NetworkPolicy" "close-route applies a NetworkPolicy"
has "$KLOG" "app: login-front" "close-route selects the front by its app label"
has "$KLOG" "ingress: \[\]" "close-route denies all ingress"

# --- close-route --remove.
export KLOG="$TMP/close-rm.log"; : > "$KLOG"
"$INC/close-route.sh" login-front --context c --remove >/dev/null 2>&1
has "$KLOG" "delete networkpolicy incident-close-login-front" "close-route --remove deletes its policy"

# --- usage errors exit non-zero.
"$INC/block-ip.sh" >/dev/null 2>&1 && { ko "block-ip with no arg should fail"; } || ok "block-ip refuses no argument"
"$INC/maintenance.sh" sideways --context c >/dev/null 2>&1 && { ko "maintenance bad mode should fail"; } || ok "maintenance refuses a bad mode"

if [ $FAILED -eq 0 ]; then echo "PASS"; else echo "FAIL"; exit 1; fi
