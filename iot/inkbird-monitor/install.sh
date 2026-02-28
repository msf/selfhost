#!/bin/bash
# Fetch and build inkbird-monitor (self-contained in repo)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="https://github.com/msf/inkbird-monitor.git"
BINARY="$SCRIPT_DIR/bin/inkbird-monitor"
TMPDIR="$(mktemp -d)"
SERVICE_USER="bleclient"
SERVICE_GROUP="bleclient"
DATA_DIR="$SCRIPT_DIR/data"
DB_FILE="$DATA_DIR/inkbird.db"
if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: Go not found. Install Go first."
    exit 1
fi
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT
# Check for BLE adapter (hciconfig is deprecated but still useful if present)
if command -v hciconfig >/dev/null 2>&1; then
    if ! hciconfig hci0 >/dev/null 2>&1; then
        echo "WARNING: No Bluetooth adapter found (hci0). Service may fail."
    fi
fi
echo "Fetching inkbird-monitor..."
git clone --depth 1 "$REPO" "$TMPDIR"
echo "Building..."
cd "$TMPDIR"
CGO_ENABLED=0 go build -ldflags="-w -s" -o inkbird-monitor .
echo "Installing binary to $BINARY..."
mkdir -p "$SCRIPT_DIR/bin"
install -Dm755 inkbird-monitor "$BINARY"
cd "$SCRIPT_DIR"
# Create env file if it doesn't exist
if [ ! -f "$SCRIPT_DIR/env" ]; then
    cp "$SCRIPT_DIR/env.example" "$SCRIPT_DIR/env"
    echo "Created $SCRIPT_DIR/env - EDIT THIS FILE with your settings!"
fi

# Create service user/group if missing
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    echo "Creating system user: $SERVICE_USER"
    sudo useradd --system --create-home --home-dir /var/lib/inkbird-monitor \
        --shell /usr/sbin/nologin --user-group "$SERVICE_USER"
fi

# Create data dir + db file and set ownership
mkdir -p "$DATA_DIR"
touch "$DB_FILE"
sudo chown -R "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
sudo chmod 750 "$DATA_DIR"
sudo chmod 640 "$DB_FILE"
# Create systemd service symlink
echo "Installing systemd service..."
sudo ln -fs "$SCRIPT_DIR/inkbird-monitor.service" /etc/systemd/system/inkbird-monitor.service
echo "Reloading systemd..."
sudo systemctl daemon-reload
echo "Enabling and starting inkbird-monitor..."
sudo systemctl enable --now inkbird-monitor
echo "Done. Check status with:"
echo "  sudo systemctl status inkbird-monitor"
echo "  journalctl -u inkbird-monitor -n 100 --no-pager"
