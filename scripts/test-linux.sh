#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
export PYTHONPATH="$root/linux"
exec /usr/bin/python3 -m unittest discover -s linux/tests -v "$@"
