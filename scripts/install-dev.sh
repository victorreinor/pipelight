#!/usr/bin/env bash
# Builds from source, replaces /Applications/Pipelight.app and opens it. The watched repos are kept:
# they live in ~/Library/Application Support/Pipelight/config.json, not inside the app.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DEST="/Applications/Pipelight.app"
if pkill -x Pipelight; then
  while pgrep -x Pipelight >/dev/null; do sleep 0.2; done
fi
rm -rf "$DEST"
cp -R build.noindex/Pipelight.app "$DEST"
# Two registered copies with one bundle id make macOS point the login item at whichever it saw last
# (often the build copy). Leave only the installed one.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u build.noindex/Pipelight.app 2>/dev/null || true
"$LSREGISTER" -f "$DEST"
open "$DEST"

echo "Installed $DEST"
