#!/usr/bin/env bash
set -euo pipefail

ROOT=$HOME/.local/share/llama.cpp
REPO=ggml-org/llama.cpp
ASSET=ubuntu-vulkan-x64
RESTART=${1:-restart}

LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
[ -n "$LATEST" ] || { echo "ERROR: failed to resolve latest tag from $REPO"; exit 1; }

TARGET="$ROOT/llama-$LATEST"

if [ -d "$TARGET" ] && [ "$(readlink -f "$ROOT/current" 2>/dev/null)" = "$TARGET" ]; then
    echo "already at $LATEST"
    exit 0
fi

mkdir -p "$ROOT"
if [ ! -d "$TARGET" ]; then
    URL="https://github.com/$REPO/releases/download/$LATEST/llama-$LATEST-bin-$ASSET.tar.gz"
    curl -fL "$URL" | tar -xz -C "$ROOT" --no-same-owner
fi

ln -sfn "$TARGET" "$ROOT/current"

if [ "$RESTART" = "restart" ] && systemctl --user is-enabled --quiet llama-server.service 2>/dev/null; then
    systemctl --user restart llama-server.service
fi

echo "llama.cpp at $LATEST"
