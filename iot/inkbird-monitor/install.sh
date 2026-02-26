#!/bin/bash
# Fetch and build inkbird-monitor (self-contained in repo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="https://github.com/msf/inkbird-monitor.git"
BINARY="$SCRIPT_DIR/bin/inkbird-monitor"
TMPDIR=$(mktemp -d)

# Detect Go installation (common paths)
for go_path in /usr/local/go/bin/go /usr/bin/go /home/linuxbrew/.linuxbrew/bin/go; do
    if [ -x "$go_path" ]; then
        export PATH="$(dirname "$go_path"):$PATH"
        break
    fi
done

if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: Go not found. Install Go first."
    exit 1
fi

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Check for BLE adapter
if ! hciconfig hci0 >/dev/null 2>&1; then
    echo "WARNING: No Bluetooth adapter found (hci0). Service may fail."
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
if [ ! -f "./env" ]; then
    cp env.example ./env
    echo "Created ./env - EDIT THIS FILE with your settings!"
fi

# Create data directory
mkdir -p ./data

# Ensure bluetooth group exists
if ! getent group bluetooth >/dev/null 2>&1; then
    echo "Creating bluetooth group..."
    groupadd -r bluetooth || true
fi

echo ""
echo "=== NEXT STEPS ==="
echo "1. Edit ./env with your settings"
echo "2. Find your Inkbird MAC: sudo hcitool lescan"
echo "3. Run: ./bin/inkbird-monitor"
echo "   Or use ./inkbird-monitor.service with systemd"
echo ""
echo "Done!"
