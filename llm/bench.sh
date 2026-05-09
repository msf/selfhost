#!/usr/bin/env bash
set -euo pipefail

# Stops llama-server, runs llama-bench across config matrix, restarts server.
# Output: markdown table with pp (prompt eval tok/s) and tg (text gen tok/s) per config.

LLAMA_DIR="$HOME/.local/share/llama.cpp/current"
BENCH="$LLAMA_DIR/llama-bench"
MODELS=/media/simple/llm/models
LOG=/tmp/llama-bench-$(date +%Y%m%d-%H%M%S).log

cleanup() {
    echo "==> restarting llama-server.service"
    systemctl --user start llama-server.service
}
trap cleanup EXIT

echo "==> stopping llama-server.service"
systemctl --user stop llama-server.service
sleep 2

cd "$LLAMA_DIR"
export LD_LIBRARY_PATH="$LLAMA_DIR"

run() {
    local label="$1"; shift
    echo
    echo "### $label"
    echo "args: $*"
    set +e
    "$BENCH" "$@" -p 512 -n 128 -r 3 -ngl 999 -t 6 2>&1 | tee -a "$LOG"
    set -e
}

GEMMA="$MODELS/google_gemma-4-E4B-it-Q6_K_L.gguf"
QWEN="$MODELS/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"

# Baseline: current Gemma config (FA on, KV q8)
run "Gemma 4 E4B Q6_K_L  | fa=1 kv=q8"   -m "$GEMMA" -fa 1 -ctk q8_0 -ctv q8_0

# Control: no flash attention, default fp16 KV (KV-quant needs FA)
run "Gemma 4 E4B Q6_K_L  | fa=0 kv=f16"  -m "$GEMMA" -fa 0

# Control: same model, fp16 KV (FA on)
run "Gemma 4 E4B Q6_K_L  | fa=1 kv=f16"  -m "$GEMMA" -fa 1

# Test: --no-mmap to force all weights into Vulkan buffer
run "Gemma 4 E4B Q6_K_L  | fa=1 kv=q8 no-mmap" -m "$GEMMA" -fa 1 -ctk q8_0 -ctv q8_0 -mmp 0

# Smaller quant: Qwen3 4B Q4_K_M
run "Qwen3 4B Q4_K_M     | fa=1 kv=q8"   -m "$QWEN"  -fa 1 -ctk q8_0 -ctv q8_0

# Thread sweep on best Gemma config
run "Gemma 4 E4B Q6_K_L  | fa=1 kv=q8 t=4" -m "$GEMMA" -fa 1 -ctk q8_0 -ctv q8_0 -t 4
run "Gemma 4 E4B Q6_K_L  | fa=1 kv=q8 t=8" -m "$GEMMA" -fa 1 -ctk q8_0 -ctv q8_0 -t 8

echo
echo "==> done. log: $LOG"
