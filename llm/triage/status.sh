#!/usr/bin/env bash
# LLM stack status — instant glance or streaming dashboard.
#
# Usage:
#   status.sh            one-shot summary (default)
#   status.sh -w [N]     stream numeric rows every N seconds (default 2)
#   status.sh -w | tee /tmp/dashboard.log
#
# Exit codes (one-shot only):  0=OK  1=GTT spill  2=service down
set -u
SWAP_BASE="${SWAP_BASE:-http://127.0.0.1:8090}"
CARD=/sys/class/drm/card0/device
PERF_LOG="${PERF_LOG:-/tmp/llm-perf.log}"

mode="snap"
interval=2
while [ $# -gt 0 ]; do
  case "$1" in
    -w) mode="watch"
        case "${2:-}" in [0-9]*) interval=$2; shift;; esac
        shift;;
    -h|--help)
        sed -n '2,8p' "$0" | sed 's/^# //'
        exit 0;;
    *) echo "usage: $0 [-w [N]]" >&2; exit 1;;
  esac
done

# ── shared helpers ────────────────────────────────────────────────────────────

vram_gib() { awk '{printf "%.2f",$1/1073741824}' "$CARD/mem_info_vram_used" 2>/dev/null || echo "?"; }
gtt_gib()  { awk '{printf "%.2f",$1/1073741824}' "$CARD/mem_info_gtt_used"  2>/dev/null || echo "?"; }
gpu_pct()  {
  local v; v=$(cat "$CARD/gpu_busy_percent" 2>/dev/null) && { echo "$v"; return; }
  # fallback: sysfs busy, try amdgpu_top single-sample
  amdgpu_top -J -n 1 -s 500 2>/dev/null \
    | python3 -c 'import sys,json
try: print(int(json.load(sys.stdin)["devices"][0]["GRBM"]["Graphics Pipe"]["value"]))
except: print("?")' 2>/dev/null || echo "?"
}

svc_prop() { systemctl --user show llama-swap.service -p "$1" 2>/dev/null | cut -d= -f2; }

mem_avail_gib()  { awk '/^MemAvailable:/{printf "%.1f",$2/1048576}' /proc/meminfo; }
swap_used_gib()  { awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{printf "%.1f",(t-f)/1048576}' /proc/meminfo; }

# ── one-shot snapshot ─────────────────────────────────────────────────────────

snap() {
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')

  # model identity — parse from /running (avoids /props round-trip; proxy may reject it)
  local model ctx slots proxy
  local running; running=$(curl -sS -m 2 "$SWAP_BASE/running" 2>/dev/null)
  read model ctx slots proxy < <(printf '%s' "$running" | python3 -c '
import sys, json, re
d = json.load(sys.stdin)
r = d.get("running", [])
if not r:
    print("(none) - - -")
    sys.exit()
item = r[0]
model = item.get("model", "?")
cmd   = item.get("cmd", "")
proxy = item.get("proxy", "")
m = re.search(r"(?:-c|--ctx-size)\s+(\d+)", cmd)
ctx = m.group(1) if m else "?"
m = re.search(r"--parallel\s+(\d+)", cmd)
slots = m.group(1) if m else "1"
print(model, ctx, slots, proxy)
' 2>/dev/null || echo "(none) - - -")

  # GPU
  local vram gtt gpu
  vram=$(vram_gib); gtt=$(gtt_gib); gpu=$(gpu_pct)
  local gtt_warn=""
  awk -v g="$gtt" 'BEGIN{if (g+0 >= 4) exit 0; exit 1}' 2>/dev/null && gtt_warn=" !! GTT SPILL"

  # RAM / swap
  local mem swap
  mem=$(mem_avail_gib); swap=$(swap_used_gib)

  # zswap pool (optional, needs debugfs or sysfs depending on kernel)
  local zswap="-"
  for p in /sys/kernel/mm/zswap/pool_total_size /sys/kernel/debug/zswap/pool_total_size; do
    [ -r "$p" ] && { zswap=$(awk '{printf "%.1f",$1/1073741824}' "$p"); break; }
  done

  # service memory (in GiB)
  local svc_cur svc_peak svc_state
  svc_state=$(systemctl --user is-active llama-swap.service 2>/dev/null || echo "unknown")
  svc_cur=$(svc_prop MemoryCurrent | awk '{printf "%.1f",$1/1073741824}')
  svc_peak=$(svc_prop MemoryPeak   | awk '{printf "%.1f",$1/1073741824}')

  # llama-server rss
  local llpid llrss="-"
  llpid=$(pgrep -x llama-server | head -1)
  [ -n "${llpid:-}" ] && llrss=$(awk '/^VmRSS:/{printf "%.1fG",$2/1048576}' /proc/"$llpid"/status 2>/dev/null || echo "?")

  # last tg/s from perf log
  local last_perf=""
  if [ -s "$PERF_LOG" ]; then
    last_perf=$(awk -F'\t' '
      $4=="eval"{m=$3; t=$7; ts=$2}
      END{if(m) printf "%s tg/s on %s (%s)", t, m, ts}
    ' "$PERF_LOG")
  fi

  printf "=== hopper LLM  %s ===\n" "$ts"
  printf "model    %-36s  ctx=%s  slots=%s\n" "$model" "$ctx" "$slots"
  printf "GPU      vram=%sG  gtt=%sG  busy=%s%%%s\n" "$vram" "$gtt" "$gpu" "$gtt_warn"
  printf "RAM      avail=%sG  swap=%sG  zswap=%sG\n" "$mem" "$swap" "$zswap"
  printf "service  %-8s  cur=%sG  peak=%sG  llama-rss=%s\n" "$svc_state" "$svc_cur" "$svc_peak" "$llrss"
  [ -n "$last_perf" ] && printf "perf     last: %s\n" "$last_perf"

  # exit code for scripting
  [ "$svc_state" != "active" ] && return 2
  [ -n "$gtt_warn" ] && return 1
  return 0
}

# ── streaming dashboard ───────────────────────────────────────────────────────
# Columns: t  cpu%  wa%  memG  swpG  si  so  r_MB  w_MB  gpu%  vramG  gttG  arcG  llama%

read_cpu() {
  read _ user nice sys idle iowait irq softirq steal _ < /proc/stat
  total=$((user+nice+sys+idle+iowait+irq+softirq+steal))
  echo "$total $((total-idle-iowait)) $iowait"
}
read_disk_bytes() {
  awk '$3!~/^(loop|ram|zram|zd|dm-)/{r+=$6;w+=$10}END{printf "%d %d",r*512,w*512}' /proc/diskstats
}
read_vmstat_pages() {
  awk '/^pswpin/{si=$2}/^pswpout/{so=$2}END{print si,so}' /proc/vmstat
}
read_llama_cpu() {
  local pid; pid=$(pgrep -x llama-server | head -1)
  [ -n "$pid" ] || { echo "0 0"; return; }
  set -- $(cat /proc/"$pid"/stat 2>/dev/null) || { echo "0 0"; return; }
  echo "${14:-0} ${15:-0}"
}

watch_stream() {
  local INTERVAL=$interval
  local CARD=/sys/class/drm/card0/device

  print_hdr() {
    printf "%5s %4s %4s %5s %5s %5s %5s %6s %6s %4s %6s %5s %5s %6s\n" \
      "t" "cpu%" "wa%" "memG" "swpG" "si" "so" "r_MB" "w_MB" "gpu%" "vramG" "gttG" "arcG" "llama%"
  }
  print_hdr
  read prev_total prev_busy prev_io <<< "$(read_cpu)"
  read prev_r prev_w <<< "$(read_disk_bytes)"
  read prev_si prev_so <<< "$(read_vmstat_pages)"
  read prev_llu prev_lls <<< "$(read_llama_cpu)"
  local ncpus; ncpus=$(nproc)
  local t=0 rows=0

  while :; do
    sleep "$INTERVAL"
    t=$((t+INTERVAL))
    rows=$((rows+1))
    [ "$rows" -gt 1 ] && [ $(( rows % 50 )) -eq 1 ] && print_hdr

    read cur_total cur_busy cur_io <<< "$(read_cpu)"
    local dt=$(( cur_total - prev_total ))
    local cpu_pct=0 wa_pct=0
    [ "$dt" -gt 0 ] && {
      cpu_pct=$(( (cur_busy-prev_busy)*100/dt ))
      wa_pct=$(( (cur_io-prev_io)*100/dt ))
    }
    prev_total=$cur_total; prev_busy=$cur_busy; prev_io=$cur_io

    read cur_r cur_w <<< "$(read_disk_bytes)"
    local rmb wmb
    rmb=$(awk -v a=$prev_r -v b=$cur_r -v t=$INTERVAL 'BEGIN{printf "%.1f",(b-a)/1048576/t}')
    wmb=$(awk -v a=$prev_w -v b=$cur_w -v t=$INTERVAL 'BEGIN{printf "%.1f",(b-a)/1048576/t}')
    prev_r=$cur_r; prev_w=$cur_w

    read cur_si cur_so <<< "$(read_vmstat_pages)"
    local si=$(( (cur_si-prev_si)/INTERVAL ))
    local so=$(( (cur_so-prev_so)/INTERVAL ))
    prev_si=$cur_si; prev_so=$cur_so

    local mem swap vram gtt gpu arc
    mem=$(mem_avail_gib)
    swap=$(swap_used_gib)
    vram=$(vram_gib)
    gtt=$(gtt_gib)
    gpu=$(gpu_pct)
    arc=$(awk '/^size /{printf "%.2f",$3/1073741824}' /proc/spl/kstat/zfs/arcstats 2>/dev/null || echo "-")

    read cur_llu cur_lls <<< "$(read_llama_cpu)"
    local djif=$(( (cur_llu+cur_lls)-(prev_llu+prev_lls) ))
    local ll_pct=0
    [ "$dt" -gt 0 ] && [ "$djif" -ge 0 ] && \
      ll_pct=$(awk -v d=$djif -v dt=$dt -v n=$ncpus 'BEGIN{printf "%.0f",(d*100/dt)*n}')
    prev_llu=$cur_llu; prev_lls=$cur_lls

    printf "%5d %4d %4d %5s %5s %5d %5d %6s %6s %4s %6s %5s %5s %6d\n" \
      "$t" "$cpu_pct" "$wa_pct" "$mem" "$swap" "$si" "$so" "$rmb" "$wmb" \
      "$gpu" "$vram" "$gtt" "$arc" "$ll_pct"
  done
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "$mode" in
  snap)  snap; exit $?;;
  watch) watch_stream;;
esac
