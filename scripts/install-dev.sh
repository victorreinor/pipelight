#!/usr/bin/env bash
# Builds from source, replaces /Applications/Esteira.app and opens it. The watched repos are kept:
# they live in ~/Library/Application Support/Esteira/config.json, not inside the app.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DEST="/Applications/Esteira.app"
if pkill -x Esteira; then
  while pgrep -x Esteira >/dev/null; do sleep 0.2; done
fi
rm -rf "$DEST"
cp -R build.noindex/Esteira.app "$DEST"
open "$DEST"

echo "Installed $DEST"
