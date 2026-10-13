#!/usr/bin/env bash
# MAIR-531: role passwords land raw in the APIs' REDIS_URL / postgres:// URL.
# seal-secrets.sh must regenerate (and verify.sh flag) any value url_safe
# rejects; the base64 passwords generated before Deploiment#50 made
# calendar-api, message-api and elearning-api fail with
# "Redis URL did not parse" on dev.
set -uo pipefail
. "$(dirname "$0")/../../scripts/lib/secret-values.sh"

FAILED=0
expect() { # expect <ok|ko> <value>
  if url_safe "$2"; then got=ok; else got=ko; fi
  if [ "$got" = "$1" ]; then echo "  OK    $1: '$2'"; else echo "  FAIL  expected $1, got $got: '$2'"; FAILED=1; fi
}

# What `openssl rand -hex 32` (seal-secrets.sh gen) produces must pass.
expect ok "$(openssl rand -hex 32)"
expect ok "Abc-1.2_3~"
# Pre-#50 `openssl rand -base64 48` shapes and every delimiter of a URL.
expect ko "q9X/Lk+Zr0=="
for c in / + = @ : '?' '#' % ' '; do expect ko "abc${c}def"; done
expect ko ""

exit "$FAILED"
