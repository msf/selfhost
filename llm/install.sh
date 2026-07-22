#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

[ -e /dev/dri/renderD128 ] || { echo "ERROR: /dev/dri/renderD128 not found"; exit 1; }
/sbin/ldconfig -p 2>/dev/null | grep -q libvulkan.so.1 || { echo "ERROR: libvulkan1 missing — one-time: sudo apt install libvulkan1 mesa-vulkan-drivers"; exit 1; }
id -nG | tr ' ' '\n' | grep -qx render || { echo "ERROR: $USER not in 'render' group (needed for /dev/dri)"; exit 1; }

MODELS=/media/simple/llm/models
MODEL_URL="https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
MODEL_FILE="$MODELS/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"

[ -w /media/simple/llm ] 2>/dev/null || mkdir -p "$MODELS" 2>/dev/null || {
    echo "ERROR: cannot create $MODELS — one-time bootstrap:"
    echo "  sudo install -d -o $USER -g staff -m 2775 /media/simple/llm /media/simple/llm/models"
    exit 1
}

./update.sh no-restart

[ -f "$MODEL_FILE" ] || curl -fL --create-dirs -o "$MODEL_FILE" "$MODEL_URL"

UNIT_DIR=$HOME/.config/systemd/user
mkdir -p "$UNIT_DIR"
ln -sf /srv/selfhost/llm/llama-swap.service "$UNIT_DIR/llama-swap.service"
systemctl --user daemon-reload
systemctl --user enable --now llama-swap.service

echo "llama-swap installed (user). test: curl -s http://127.0.0.1:8090/v1/models"
echo "for autostart at boot without login: sudo loginctl enable-linger $USER  (one-time, optional)"
