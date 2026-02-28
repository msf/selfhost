#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="$SCRIPT_DIR/bin/inkbird-monitor"
SERVICE_USER="bleclient"
SERVICE_GROUP="staff"

# Prerequisites
command -v go >/dev/null 2>&1 || { echo "ERROR: Go not found"; exit 1; }
getent group "$SERVICE_GROUP" >/dev/null 2>&1 || { echo "ERROR: Group '$SERVICE_GROUP' not found"; exit 1; }

# Build
mkdir -p "$SCRIPT_DIR/bin"
GOPROXY=direct GOBIN="$SCRIPT_DIR/bin" CGO_ENABLED=0 go install -ldflags="-w -s" github.com/msf/inkbird-monitor@latest

# Save build metadata
BUILDINFO="$SCRIPT_DIR/bin/inkbird-monitor.buildinfo"
[ -f "$BUILDINFO" ] && mv -f "$BUILDINFO" "$BUILDINFO.old"
go version -m "$BINARY" > "$BUILDINFO"

# Env file (first-time only)
if [ ! -f "$SCRIPT_DIR/env" ]; then
    cp "$SCRIPT_DIR/env.example" "$SCRIPT_DIR/env"
    echo "Created $SCRIPT_DIR/env from template — edit it and rerun."
    exit 1
fi

# Service user (idempotent)
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    sudo useradd --system --gid "$SERVICE_GROUP" --groups bluetooth \
        --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

# Data dir
mkdir -p "$SCRIPT_DIR/data"
touch "$SCRIPT_DIR/data/payloads.db"
sudo chown -R "$SERVICE_USER:$SERVICE_GROUP" "$SCRIPT_DIR/data"
sudo chmod 2775 "$SCRIPT_DIR/data"

# Systemd
sudo ln -sfn "$SCRIPT_DIR/inkbird-monitor.service" /etc/systemd/system/inkbird-monitor.service
sudo systemctl daemon-reload
sudo systemctl enable --now inkbird-monitor
sudo systemctl restart inkbird-monitor

echo "Done. Status: sudo systemctl status inkbird-monitor"
journalctl -u inkbird-monitor -n 20 
