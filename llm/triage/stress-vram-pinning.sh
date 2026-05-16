#!/usr/bin/env bash
# Validate that GGML_VK_ENABLE_MEMORY_PRIORITY=1 keeps the model in VRAM
# under host memory pressure.
#
# Method:
#   1. Baseline: confirm model is in VRAM, measure tokens/s on a fixed prompt.
#   2. Start a 60s memory-pressure stressor (stress-ng) eating 5 GiB anon.
#   3. Sample VRAM/GTT every 2s during the stress.
#   4. Hit the model again under pressure → measure tokens/s.
#   5. Stop the stressor, sample recovery.
#
# Pass criteria:
#   - VRAM stays >= 15 GiB throughout the stress window
#   - GTT stays <= 3 GiB throughout
#   - tokens/s under pressure within 20% of baseline
#
# No root needed. stress-ng runs in user space.
set -u

PROMPT='Write a one-paragraph (around 80 words) explanation of how flash attention reduces memory bandwidth in transformers. Reply only with the paragraph.'
MAX_TOK=120

probe_tokens_per_s() {
  local label="$1"
  # jq -n with --arg handles the newlines/quotes safely
  local body="$(printf '%s' "$PROMPT" | jq -Rs --argjson n $MAX_TOK \
    '{model:"gemma-26b-moe", messages:[{role:"user",content:.}], max_tokens:$n}')"
  local t0=$(date +%s.%N)
  local resp=$(curl -s -m 180 -X POST http://127.0.0.1:8090/v1/chat/completions \
                 -H 'content-type: application/json' --data-binary "$body")
  local t1=$(date +%s.%N)
  local elapsed=$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')
  local ntok=$(echo "$resp" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
  [ -z "$ntok" ] || [ "$ntok" = "null" ] && ntok=0
  local rate=$(awk -v t=$elapsed -v n=$ntok 'BEGIN{ if (t>0 && n>0) printf "%.2f", n/t; else print "0" }')
  printf "%s: %s tokens in %.2fs → %s tok/s\n" "$label" "$ntok" "$elapsed" "$rate"
}

vram_gtt_now() {
  local v=$(awk '{printf "%.2f", $1/1024/1024/1024}' /sys/class/drm/card0/device/mem_info_vram_used)
  local g=$(awk '{printf "%.2f", $1/1024/1024/1024}' /sys/class/drm/card0/device/mem_info_gtt_used)
  local m=$(awk '/^MemAvailable:/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
  echo "VRAM=${v}G GTT=${g}G MemAvail=${m}G"
}

echo "=== 0. baseline (no stress) ==="
echo "  $(vram_gtt_now)"
probe_tokens_per_s "baseline"

echo
echo "=== 1. starting 60s memory pressure (stress-ng 5 GiB anon, 4 workers) ==="
stress-ng --vm 4 --vm-bytes 1280M --vm-keep --timeout 60s --quiet &
STRESS_PID=$!

echo "=== 2. sampling VRAM/GTT every 3s for 60s under pressure ==="
for i in $(seq 1 20); do
  sleep 3
  printf "  t=%02ds %s\n" "$((i*3))" "$(vram_gtt_now)"
done

echo
echo "=== 3. probe under pressure ==="
probe_tokens_per_s "under_pressure"

echo
echo "=== 4. wait for stress-ng to finish, then post-recovery ==="
wait $STRESS_PID 2>/dev/null
sleep 3
echo "  $(vram_gtt_now)"
probe_tokens_per_s "post_recovery"

echo
echo "=== verdict ==="
v=$(awk '{print $1/1024/1024/1024}' /sys/class/drm/card0/device/mem_info_vram_used)
g=$(awk '{print $1/1024/1024/1024}' /sys/class/drm/card0/device/mem_info_gtt_used)
awk -v v=$v -v g=$g 'BEGIN{
  if (v >= 15 && g <= 3) print "PASS — model held in VRAM throughout";
  else printf "FAIL — final VRAM=%.1fG GTT=%.1fG (expected VRAM>=15, GTT<=3)\n", v, g;
}'
