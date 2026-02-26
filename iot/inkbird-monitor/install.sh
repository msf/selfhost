#!/bin/bash
# Fetch, build and install inkbird-monitor with systemd service
set -euo pipefail

REPO="https://github.com/msf/inkbird-monitor.git"
BINARY="/usr/local/bin/inkbird-monitor"
CONFIG_DIR="/etc/inkbird-monitor"
TMPDIR=$(mktemp -d)

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

echo "Creating config directory..."
mkdir -p "$CONFIG_DIR"

# Create env file if it doesn't exist
if [ ! -f "$CONFIG_DIR/env" ]; then
    cat > "$CONFIG_DIR/env" << 'EOF'
# Inkbird IAM-T1 Configuration
# Get device address with: sudo hcitool lescan

DEVICE_ADDR=62:00:A1:3F:B4:26
MQTT_SERVER=tcp://localhost:1883
MQTT_USERNAME=
MQTT_PASSWORD=
VM_ENDPOINT=http://localhost:8428/api/v1/write
DB_PATH=/var/lib/inkbird-monitor/payloads.db
EOF
    echo "Created $CONFIG_DIR/env - EDIT THIS FILE with your settings!"
fi

# Create systemd service
echo "Installing systemd service..."
cat > /etc/systemd/system/inkbird-monitor.service << 'EOF'
[Unit]
Description=Inkbird IAM-T1 CO2 Monitor
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/inkbird-monitor/env
ExecStart=/usr/local/bin/inkbird-monitor
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

# Bluetooth permissions
DeviceAllow=/dev/hci0 r

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/inkbird-monitor /var/log

[Install]
WantedBy=multi-user.target
EOF

# Create data directory
mkdir -p /var/lib/inkbird-monitor

echo "Reloading systemd..."
systemctl daemon-reload

echo "Enabling inkbird-monitor..."
systemctl enable inkbird-monitor

echo ""
echo "=== NEXT STEPS ==="
echo "1. Edit $CONFIG_DIR/env with your settings:"
echo "   - DEVICE_ADDR: MAC address of your Inkbird sensor"
echo "   - MQTT_SERVER: Your MQTT broker (e.g., tcp://localhost:1883)"
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
