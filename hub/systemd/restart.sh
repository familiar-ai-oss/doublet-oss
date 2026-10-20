#!/usr/bin/env bash
# Run on the hub machine (make restart-hub). Refuses while the lead is mid-turn or has queued prompts.
set -euo pipefail
port=${DUET_PORT:-7811}
health() { curl -fsS --max-time 3 "http://127.0.0.1:$port/health"; }

if h=$(health 2>/dev/null); then
  if [[ $h == *'"busy":true'* ]]; then
    echo "refusing to restart: the lead is busy ($h). Wait for the turn to finish, or interrupt it from a client." >&2
    exit 1
  fi
  echo "before: $h"
else
  echo "hub not answering /health; restarting anyway"
fi

systemctl --user restart duet-hub
for _ in $(seq 1 30); do
  if h=$(health 2>/dev/null); then echo "after:  $h"; exit 0; fi
  sleep 1
done
echo "hub did not come back within 30 s; see: make hub-logs" >&2
exit 1
