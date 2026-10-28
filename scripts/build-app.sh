#!/usr/bin/env bash
# Builds build.noindex/Esteira.app: release, universal (Apple Silicon + Intel), ad-hoc signed.
# No Xcode needed, just the Command Line Tools (xcode-select --install).
# The ".noindex" suffix keeps Spotlight from listing this copy next to /Applications/Esteira.app.
# Version: $VERSION (the release workflow passes the new one), else the latest vX.Y.Z tag.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build.noindex/Esteira.app"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)}"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}" --product Esteira
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

if [ ! -f Resources/AppIcon.icns ]; then
  rm -rf build.noindex/AppIcon.iconset
  swift scripts/make-icon.swift build.noindex/AppIcon.iconset
  iconutil -c icns build.noindex/AppIcon.iconset -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Esteira" "$APP/Contents/MacOS/Esteira"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"
