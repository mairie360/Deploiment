#!/usr/bin/env bash
# Application denial-of-service run of the external attack campaigns. RUN FROM THE
# DISPOSABLE SOURCE MACHINE (mairie360/Infra attack-source), NEVER from a GitHub runner, inside the
# denial-of-service sub-window of an announced campaign, raised by steps and stopped at the first
# breaking point (docs/en/external-attack-campaigns.md).
#
# Two-handed: this drives the attack from the source machine; the Argo CD machine captures the
# cluster snapshots (snapshot.sh) into the same per-scenario directory. Then dos.py aggregates.
#
#   BASE=https://login.staging.mairie360-eip.fr LEGIT_COOKIE="accessToken=..." \
#     ./run.sh http-burst-login report/
#
# Needs k6 and slowhttptest on the source machine. Each scenario writes attack-summary.json and
# legit-summary.json into report/<scenario>/; the operator drops the kubectl snapshots and
# recovery.json there too (see snapshot.sh / the README) before running dos.py.
set -euo pipefail

SCENARIO=${1:?scenario name, e.g. http-burst-login}
OUT=${2:?output directory}
BASE=${BASE:?set BASE to the target front origin}
dir="$OUT/$SCENARIO"
mkdir -p "$dir"
RPS=${RPS:-200}
DURATION=${DURATION:-120s}

echo "== $SCENARIO against $BASE (RPS=$RPS, $DURATION). Legitimate agent runs in parallel. =="
# The legitimate agent first, in the background, so it measures latency during the whole attack.
k6 run -e BASE="$BASE" -e COOKIE="${LEGIT_COOKIE:-}" -e DURATION="$DURATION" \
  --summary-export="$dir/legit-summary.json" k6/legit.js &
legit=$!

case "$SCENARIO" in
  http-burst-login)
    k6 run -e BASE="$BASE" -e TARGET=/api/auth/login -e RPS="$RPS" -e DURATION="$DURATION" \
      --summary-export="$dir/attack-summary.json" k6/attack.js ;;
  http-burst-search)
    k6 run -e BASE="$BASE" -e METHOD=GET -e TARGET="/projects-page?filter=a" -e RPS="$RPS" \
      -e DURATION="$DURATION" --summary-export="$dir/attack-summary.json" k6/attack.js ;;
  slow-connections)
    # Slow headers and body; -c many connections held open, -H slow-headers mode.
    slowhttptest -c 1000 -H -i 10 -r 200 -t GET -u "$BASE/" -x 24 -p 3 -l "${DURATION%s}" \
      -g -o "$dir/slowhttptest" || true
    : > "$dir/attack-summary.json" ;;
  oversized-body)
    head -c "$((60 * 1024 * 1024))" /dev/zero | tr '\0' 'a' > /tmp/big.bin
    k6 run -e BASE="$BASE" -e METHOD=POST -e TARGET=/api/auth/login -e RPS=20 -e DURATION="$DURATION" \
      -e BODY="@/tmp/big.bin" --summary-export="$dir/attack-summary.json" k6/attack.js ;;
  nested-json|unbounded-pagination|mass-websocket)
    echo "scenario $SCENARIO: see the README for its generator; writes attack-summary.json" ;;
  *)
    echo "unknown scenario $SCENARIO" >&2; exit 2 ;;
esac

wait "$legit" || true
echo "== $SCENARIO done. Collect pods-before/after.json, top-after.txt and recovery.json into $dir, then run dos.py. =="
