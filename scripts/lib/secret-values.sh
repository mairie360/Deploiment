# shellcheck shell=bash
# Helpers shared by scripts/seal-secrets.sh and scripts/verify.sh (sourced).

# url_safe <value>: true when <value> is non-empty and made only of RFC 3986
# unreserved characters, so it can sit in the userinfo of a URL without
# percent-encoding. The chart builds `redis://user:$(REDIS_PASSWORD)@host`
# and the APIs build `postgres://user:password@host` from raw Secret values
# (Kubernetes `$(VAR)` expansion cannot encode): a `/`, `+`, `=`, `@`, `:`,
# `?` or `#` makes the API fail with "Redis URL did not parse" or "invalid
# port number". Passwords generated before Deploiment#50 were base64 (MAIR-531).
url_safe() {
  [ -n "${1:-}" ] && [[ "$1" =~ ^[A-Za-z0-9._~-]+$ ]]
}
