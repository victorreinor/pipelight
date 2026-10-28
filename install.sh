#!/usr/bin/env bash
# Installs (or updates) the latest Esteira release:
#
#   curl -fsSL https://raw.githubusercontent.com/victorreinor/esteira/main/install.sh | bash
#
# Downloads Esteira.zip from GitHub Releases, puts Esteira.app in /Applications
# (or ~/Applications when /Applications isn't writable) and opens it. The watched repos are kept.
set -euo pipefail

REPO="victorreinor/esteira"
URL="https://github.com/$REPO/releases/latest/download/Esteira.zip"

if [ "$(uname)" != "Darwin" ]; then
  echo "O Esteira só roda no macOS." >&2
  exit 1
fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 14 ]; then
  echo "O Esteira precisa do macOS 14 (Sonoma) ou mais novo. Este Mac está no $(sw_vers -productVersion)." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "→ Baixando a última versão do Esteira…"
curl -fsSL "$URL" -o "$tmp/Esteira.zip"
ditto -x -k "$tmp/Esteira.zip" "$tmp"

dest="/Applications"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

if pkill -x Esteira; then
  while pgrep -x Esteira >/dev/null; do sleep 0.2; done
fi

echo "→ Instalando em $dest/Esteira.app"
rm -rf "$dest/Esteira.app"
ditto "$tmp/Esteira.app" "$dest/Esteira.app"
# The app isn't notarized by Apple; without this macOS would refuse to open it.
xattr -dr com.apple.quarantine "$dest/Esteira.app" 2>/dev/null || true

open "$dest/Esteira.app"
echo "✓ Pronto! O ícone do Esteira apareceu na barra de menus, perto do relógio."

if ! command -v gh >/dev/null 2>&1; then
  echo
  echo "⚠︎ Falta o GitHub CLI, que o Esteira usa para falar com o GitHub:"
  echo "    brew install gh && gh auth login"
elif ! gh auth status >/dev/null 2>&1; then
  echo
  echo "⚠︎ Falta fazer login no GitHub CLI:"
  echo "    gh auth login"
fi
