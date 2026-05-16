#!/usr/bin/env bash
# Live perf monitor for llama-swap — tails the SSE log of the currently
# loaded model and appends each prompt-eval / eval-time line to a perf
# log with timestamp + model name. Survives model swaps by polling
# /running and re-attaching when the SSE breaks.
#
# Output schema (TSV):
#   <epoch_ms>\t<isodate>\t<model>\t<phase>\t<ms>\t<tokens>\t<tok_per_s>
#   phase ∈ {prompt, eval}
#
# Usage:
#   /srv/selfhost/llm/triage/perf-monitor.sh > /tmp/llm-perf.log &
#   tail -f /tmp/llm-perf.log
set -u
SWAP_BASE="${SWAP_BASE:-http://127.0.0.1:8090}"

current_model() {
  curl -sS -m 3 "$SWAP_BASE/running" 2>/dev/null \
    | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get("running", [])
    if r: print(r[0]["model"])
except Exception:
    pass
'
}

tail_one_model() {
  local m="$1"
  # parse SSE: each "eval time" line emits one TSV row
  curl -sN -m 86400 "$SWAP_BASE/logs/stream/$m" 2>/dev/null \
    | awk -v m="$m" '
      /prompt eval time = / {
        # format: "prompt eval time = 2251.11 ms / 281 tokens ( 8.01 ms per token, 124.83 tokens per second)"
        # capture: ms_total, tokens, tok_per_s. Non-greedy via splits on ", "
        match($0, /=[[:space:]]*([0-9.]+)[[:space:]]*ms[[:space:]]*\/[[:space:]]*([0-9]+)[[:space:]]*tokens/, a);
        match($0, /,[[:space:]]+([0-9.]+)[[:space:]]+tokens per second/, b);
        a[3] = b[1]
        if (a[3] != "") {
          ts = strftime("%Y-%m-%dT%H:%M:%S")
          ems = systime() * 1000
          printf "%d\t%s\t%s\tprompt\t%s\t%s\t%s\n", ems, ts, m, a[1], a[2], a[3]; fflush()
        }
      }
      /^[[:space:]]*eval time = / {
        # capture: ms_total, tokens, tok_per_s. Non-greedy via splits on ", "
        match($0, /=[[:space:]]*([0-9.]+)[[:space:]]*ms[[:space:]]*\/[[:space:]]*([0-9]+)[[:space:]]*tokens/, a);
        match($0, /,[[:space:]]+([0-9.]+)[[:space:]]+tokens per second/, b);
        a[3] = b[1]
        if (a[3] != "") {
          ts = strftime("%Y-%m-%dT%H:%M:%S")
          ems = systime() * 1000
          printf "%d\t%s\t%s\teval\t%s\t%s\t%s\n", ems, ts, m, a[1], a[2], a[3]; fflush()
        }
      }
    '
}

# Header
printf "epoch_ms\tisodate\tmodel\tphase\tms\ttokens\ttok_per_s\n"

last_model=""
while :; do
  m=$(current_model)
  if [ -z "$m" ]; then
    sleep 2
    continue
  fi
  if [ "$m" != "$last_model" ]; then
    last_model="$m"
    # restart tail on new model
  fi
  tail_one_model "$m"   # blocks until stream closes (model evict / 502)
  sleep 1
done
