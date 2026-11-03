#!/usr/bin/env bash
# Source distribution: GTK uses the host distribution's native libraries.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
./scripts/test-linux.sh
mkdir -p build.noindex
tar --exclude='__pycache__' --exclude='*.pyc' --transform='s,^,pipelight-linux/,' \
    -czf build.noindex/Pipelight-linux.tar.gz linux LICENSE scripts/install-linux.sh scripts/test-linux.sh
echo "✓ Pacote: $root/build.noindex/Pipelight-linux.tar.gz"
