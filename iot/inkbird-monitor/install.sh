#!/bin/bash
# Fetch, build and install inkbird-monitor with systemd service
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="https://github.com/msf/inkbird-monitor.git"
BINARY="/usr/local/bin/inkbird-monitor"
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
install -Dm755 inkbird-monitor "$BINARY"

cd "$SCRIPT_DIR"

# Create env file if it doesn't exist
if [ ! -f "./env" ]; then
    cat > "./env" << 'EOF'
# Inkbird IAM-T1 Configuration
# Get device address with: sudo hcitool lescan

DEVICE_ADDR=62:00:A1:3F:B4:26
MQTT_SERVER=tcp://localhost:1883
MQTT_USERNAME=
MQTT_PASSWORD=
VM_ENDPOINT=http://localhost:8428/api/v1/write
DB_PATH=./data/payloads.db
EOF
    echo "Created ./env - EDIT THIS FILE with your settings!"
fi

# Create data directory
mkdir -p ./data

# Ensure bluetooth group exists
if ! getent group bluetooth >/dev/null 2>&1; then
    echo "Creating bluetooth group..."
    groupadd -r bluetooth || true
fi

# Install systemd service
echo "Installing systemd service..."
install -Dm644 inkbird-monitor.service /etc/systemd/system/inkbird-monitor.service

# Update service to use relative paths from repo directory
sed -i "s|ExecStart=.*|ExecStart=$BINARY|" /etc/systemd/system/inkbird-monitor.service

# Add environment file path to service
if ! grep -q "EnvironmentFile=" /etc/systemd/system/inkbird-monitor.service; then
    sed -i '/\[Service\]/a EnvironmentFile='"$SCRIPT_DIR"'/env' /etc/systemd/system/inkbird-monitor.service
fi

echo "Reloading systemd..."
systemctl daemon-reload

echo "Enabling inkbird-monitor..."
systemctl enable inkbird-monitor

echo ""
echo "=== NEXT STEPS ==="
echo "1. Edit $SCRIPT_DIR/env with your settings:"
echo "   - DEVICE_ADDR: MAC address of your Inkbird sensor"
echo "   - MQTT_SERVER: Your MQTT broker"
echo "   - MQTT_USERNAME / MQTT_PASSWORD: MQTT credentials"
echo ""
echo "2. Find your Inkbird MAC address:"
echo "   sudo hcitool lescan"
echo ""
echo "3. Start the service:"
echo "   sudo systemctl start inkbird-monitor"
echo ""
echo "4. Check status:"
echo "   sudo systemctl status inkbird-monitor"
echo "   journalctl -u inkbird-monitor -f"
echo ""
echo "Done!"
