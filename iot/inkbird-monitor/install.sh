#!/bin/bash
# Fetch and build inkbird-monitor from GitHub
set -euo pipefail

REPO="https://github.com/msf/inkbird-monitor.git"
BINARY="/usr/local/bin/inkbird-monitor"
TMPDIR=$(mktemp -d)

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "Fetching inkbird-monitor..."
git clone --depth 1 "$REPO" "$TMPDIR"

echo "Building..."
cd "$TMPDIR"
CGO_ENABLED=0 go build -ldflags="-w -s" -o iam-t1-exporter .

echo "Installing to $BINARY..."
install -Dm755 iam-t1-exporter "$BINARY"

echo "Done. Run: inkbird-monitor --help"
