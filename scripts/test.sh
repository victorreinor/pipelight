#!/usr/bin/env bash
# `swift test`, plus the Swift Testing macro plugin path. With only the Command Line Tools
# installed, SwiftPM intermittently fails to find it:
#   "external macro implementation type 'TestingMacros…' could not be found"
set -euo pipefail
cd "$(dirname "$0")/.."

args=()
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
  args=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi
swift test ${args[@]+"${args[@]}"} "$@"
