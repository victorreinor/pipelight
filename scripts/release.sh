#!/usr/bin/env bash
# Publishes the next version as a GitHub release with build.noindex/Pipelight.zip. The version comes
# from scripts/next-version.sh: patch by default, "[minor]" or "[major]" in the subject of a commit
# since the last tag, or the part given here. The notes default to those commits' subjects.
# install.sh always fetches the latest release.
#
#   ./scripts/release.sh                       # 0.1.0 → 0.1.1
#   ./scripts/release.sh minor "Notas"         # 0.1.0 → 0.2.0, with these notes
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "Commit your changes before releasing." >&2
  exit 1
fi

version="$(./scripts/next-version.sh "${1:-auto}")"
tag="v$version"
previous="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
notes="${2:-$(git log ${previous:+"$previous..HEAD"} --no-merges --format='- %s')}"

./scripts/test.sh
VERSION="$version" ./scripts/build-app.sh
rm -f build.noindex/Pipelight.zip
ditto -c -k --keepParent build.noindex/Pipelight.app build.noindex/Pipelight.zip

# Annotated, so it also works when tag.gpgsign is on (signed tags need a message).
git tag -a "$tag" -m "Pipelight $version"
git push origin "$tag"
gh release create "$tag" build.noindex/Pipelight.zip --title "Pipelight $version" --notes "$notes"
