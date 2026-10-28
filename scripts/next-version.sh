#!/usr/bin/env bash
# Prints the next release version: the latest vX.Y.Z tag with one part bumped. The part is the
# argument (patch, minor or major); with none or "auto", it's "[major]" or "[minor]" when the
# subject (first line) of a commit since that tag says so, and patch otherwise. Only subjects
# count, so a commit body can mention the markers without bumping anything.
#
#   ./scripts/next-version.sh          # 0.1.0 → 0.1.1
#   ./scripts/next-version.sh minor    # 0.1.0 → 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

last="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
IFS=. read -r major minor patch <<< "${last#v}"

bump="${1:-auto}"
if [ "$bump" = auto ]; then
  subjects="$(git log ${last:+"$last..HEAD"} --format=%s)"
  if grep -qF '[major]' <<< "$subjects"; then
    bump=major
  elif grep -qF '[minor]' <<< "$subjects"; then
    bump=minor
  else
    bump=patch
  fi
fi

case "$bump" in
  major) echo "$((${major:-0} + 1)).0.0" ;;
  minor) echo "${major:-0}.$((${minor:-0} + 1)).0" ;;
  patch) echo "${major:-0}.${minor:-0}.$((${patch:-0} + 1))" ;;
  *) echo "Unknown bump '$bump': use patch, minor, major or auto." >&2; exit 1 ;;
esac
