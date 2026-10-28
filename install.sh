#!/usr/bin/env bash
# Installs (or updates) the latest Pipelight release:
#
#   curl -fsSL https://raw.githubusercontent.com/victorreinor/pipelight/main/install.sh | bash
#
# Downloads Pipelight.zip from GitHub Releases, puts Pipelight.app in /Applications
# (or ~/Applications when /Applications isn't writable) and opens it. The watched repos are kept.
set -euo pipefail

REPO="victorreinor/pipelight"
URL="https://github.com/$REPO/releases/latest/download/Pipelight.zip"

if [ "$(uname)" != "Darwin" ]; then
  echo "O Pipelight só roda no macOS." >&2
  exit 1
fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 14 ]; then
  echo "O Pipelight precisa do macOS 14 (Sonoma) ou mais novo. Este Mac está no $(sw_vers -productVersion)." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "→ Baixando a última versão do Pipelight…"
curl -fsSL "$URL" -o "$tmp/Pipelight.zip"
ditto -x -k "$tmp/Pipelight.zip" "$tmp"

dest="/Applications"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

if pkill -x Pipelight; then
  while pgrep -x Pipelight >/dev/null; do sleep 0.2; done
fi

echo "→ Instalando em $dest/Pipelight.app"
rm -rf "$dest/Pipelight.app"
ditto "$tmp/Pipelight.app" "$dest/Pipelight.app"
# The app isn't notarized by Apple; without this macOS would refuse to open it.
xattr -dr com.apple.quarantine "$dest/Pipelight.app" 2>/dev/null || true

open "$dest/Pipelight.app"
echo "✓ Pronto! O ícone do Pipelight apareceu na barra de menus, perto do relógio."

if ! command -v gh >/dev/null 2>&1; then
  echo
  echo "⚠︎ Falta o GitHub CLI, que o Pipelight usa para falar com o GitHub:"
  echo "    brew install gh && gh auth login"
elif ! gh auth status >/dev/null 2>&1; then
  echo
  echo "⚠︎ Falta fazer login no GitHub CLI:"
  echo "    gh auth login"
fi
