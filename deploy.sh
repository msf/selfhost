#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[ -f ~/.age-key.txt ] || { echo "ERROR: ~/.age-key.txt not found"; exit 1; }
[ -f secrets.tar.age ] || { echo "ERROR: secrets.tar.age not found"; exit 1; }
age -d -i ~/.age-key.txt secrets.tar.age | tar xzf -
ln -sf env immich/.env
echo "Secrets decrypted: caddy/env ddns/env immich/env"
