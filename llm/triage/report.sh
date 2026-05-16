#!/usr/bin/env bash
# LLM historical report — journal + perf log analysis.
#
# Mines llama-swap and hermes-gateway journals to surface:
#   - model load/unload activity
#   - request counts, error rates, approximate throughput per model
#   - service crashes / OOM kills
#   - config reload events (yaml churn)
#   - precise tg/s stats from perf-monitor log (if running)
#
# Usage:
#   report.sh                    last 24h
#   report.sh --since "2 days ago"
#   report.sh --since 2026-05-07
set -u

SINCE="${1:-}"
[ "$SINCE" = "--since" ] && SINCE="${2:-}" && shift 2 2>/dev/null || true
[ -z "$SINCE" ] && SINCE="yesterday"

PERF_LOG="${PERF_LOG:-/tmp/llm-perf.log}"

jctl_swap()   { journalctl --user -u llama-swap.service   --since "$SINCE" --no-pager 2>/dev/null; }
jctl_hermes() { journalctl --user -u hermes-gateway.service --since "$SINCE" --no-pager 2>/dev/null; }

hr() { printf "\n=== %s ===\n" "$1"; }

# ── 1. MODEL ACTIVITY ─────────────────────────────────────────────────────────

hr "model activity (since $SINCE)"
jctl_swap | awk '
  /Health check passed/ {
    match($0, /<([^>]+)>/, a); m=a[1]
    loads[m]++
    printf "  LOAD   %-20s %s %s %s\n", m, $1, $2, $3
  }
  /Unloading model/ {
    match($0, /<([^>]+)>/, a); m=a[1]
    unloads[m]++
    printf "  EVICT  %-20s %s %s %s\n", m, $1, $2, $3
  }
  /ExitError.*signal: killed/ {
    match($0, /<([^>]+)>/, a); m=a[1]
    kills[m]++
    printf "  KILL   %-20s %s %s %s\n", m, $1, $2, $3
  }
  END {
    printf "\nSummary:\n"
    printf "%-22s %6s %7s %5s\n", "model", "loads", "unloads", "kills"
    for (m in loads) printf "%-22s %6d %7d %5d\n", m, loads[m]+0, unloads[m]+0, kills[m]+0
  }
'

# ── 2. REQUESTS PER MODEL ─────────────────────────────────────────────────────

hr "requests per model"
jctl_swap | awk '
  /Health check passed/ {
    match($0, /<([^>]+)>/, a); cur=a[1]
  }
  /Unloading model/ { cur="" }
  /ExitError.*signal: killed/ { cur="" }

  # request line: 200 <bytes> "User-Agent" <dur>s  (duration has no quotes)
  /POST \/v1\/chat\/completions.*200/ {
    match($0, /200 ([0-9]+) "/, b); sz=b[1]+0
    # duration at end of line: "1m40.69s" or "55.72s"
    match($0, / ([0-9]+)m([0-9.]+)s$/, c2)
    match($0, / ([0-9.]+)s$/, c1)
    dur = 0
    if (c2[1] != "") { dur = c2[1]*60 + c2[2]+0 }
    else if (c1[1] != "") { dur = c1[1]+0 }
    if (dur > 0 && cur != "") {
      n[cur]++; total_dur[cur]+=dur
      if (dur > max_dur[cur]+0) max_dur[cur]=dur
    }
  }

  /non-200 response/ { err_model[cur]++ }
  /error processing streaming/ { stream_err[cur]++ }

  END {
    printf "%-22s %6s %8s %9s %9s\n", "model", "n_req", "err", "avg_dur_s", "max_dur_s"
    for (m in n) {
      printf "%-22s %6d %8d %9.1f %9.1f\n", \
        m, n[m], err_model[m]+0, total_dur[m]/n[m], max_dur[m]+0
    }
  }
' | sort

# ── 3. ERRORS DETAIL ──────────────────────────────────────────────────────────

hr "errors (non-200, kills, streaming failures)"
jctl_swap | grep -E 'WARN.*non-200|ExitError|error processing stream|oom-kill|OOM' | \
  awk '{
    # strip leading timestamp fields (up to the process name)
    sub(/^.*llama-swap\[[0-9]+\]: /, "")
    print
  }' | sort | uniq -c | sort -rn | head -20

# ── 4. CONFIG RELOAD CHURN ────────────────────────────────────────────────────

hr "config reload events (each = yaml edit triggered live reload)"
jctl_swap | grep "Configuration Reloaded" | awk '{print $1, $3}' | head -20
total_reloads=$(jctl_swap | grep -c "Configuration Reloaded" 2>/dev/null; true)
printf "total reloads: %s\n" "$total_reloads"

# ── 5. SERVICE RESTARTS / CRASHES ─────────────────────────────────────────────

hr "service lifecycle events"
journalctl --user -u llama-swap.service --since "$SINCE" --no-pager 2>/dev/null \
  | grep -E 'Started|Stopped|Failed|oom-kill|Consumed' \
  | awk '{sub(/^.*systemd\[[0-9]+\]: /, ""); print $0}' | head -20

# ── 6. HERMES GATEWAY ─────────────────────────────────────────────────────────

hr "hermes-gateway: starts, stops, failures"
journalctl --user -u hermes-gateway.service --since "$SINCE" --no-pager 2>/dev/null \
  | grep -E 'Started|Stopped|Failed|Consumed|WARNING|ERROR' \
  | awk '{sub(/^.*\[?[a-z]+\]?\[[0-9]+\]: /, ""); print}' | head -30

# ── 7. PRECISE TG/S FROM PERF MONITOR ────────────────────────────────────────

if [ -s "$PERF_LOG" ]; then
  hr "precise tg/s from perf-monitor (perf-monitor.sh data in $PERF_LOG)"

  echo "--- eval (generation) rate ---"
  printf "%-24s %6s %6s %6s %6s  %s\n" "model" "n" "min" "avg" "max" "last_ts"
  awk -F'\t' '
    NR>1 && $4=="eval" {
      m=$3; t=$7+0; n[m]++; sum[m]+=t
      if (!min[m] || t<min[m]) min[m]=t
      if (t>max[m]) max[m]=t
      last_ts[m]=$2
    }
    END {
      for (m in n)
        printf "%-24s %6d %6.1f %6.1f %6.1f  %s\n", m, n[m], min[m], sum[m]/n[m], max[m], last_ts[m]
    }
  ' "$PERF_LOG" | sort

  echo ""
  echo "--- prompt-processing rate (prefill) ---"
  printf "%-24s %6s %8s\n" "model" "n" "avg_pp_tps"
  awk -F'\t' '
    NR>1 && $4=="prompt" {
      m=$3; t=$7+0; n[m]++; sum[m]+=t
    }
    END {
      for (m in n) printf "%-24s %6d %8.1f\n", m, n[m], sum[m]/n[m]
    }
  ' "$PERF_LOG" | sort

  echo ""
  echo "--- last 5 eval entries ---"
  awk -F'\t' 'NR>1 && $4=="eval"' "$PERF_LOG" | tail -5 | \
    awk -F'\t' '{printf "%s  %-24s %s tok/s  (%s ms / %s tok)\n", $2, $3, $7, $5, $6}'
else
  echo ""
  echo "(no $PERF_LOG — run perf-monitor.sh in background to collect live data)"
fi

# ── 8. CURRENT STATE ──────────────────────────────────────────────────────────

hr "current state"
bash "$(dirname "$0")/status.sh" 2>/dev/null || true
