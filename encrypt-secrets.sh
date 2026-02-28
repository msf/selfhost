#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[ -f ~/.age-key.txt ] || { echo "ERROR: ~/.age-key.txt not found"; exit 1; }
tar czf secrets.tar caddy/env ddns/env immich/env openclaw/env iot/inkbird-monitor/env
age -r $(age-keygen -y ~/.age-key.txt) -o secrets.tar.age secrets.tar
rm secrets.tar
echo "Encrypted: secrets.tar.age"
