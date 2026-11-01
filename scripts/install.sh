#!/bin/bash
# Builds from source and installs into /Applications (or ~/Applications).
# Needs macOS 14.2+ and the Command Line Tools (xcode-select --install).
set -euo pipefail

cd "$(dirname "$0")/.."
command -v swift >/dev/null || { echo "Swift not found. Run: xcode-select --install" >&2; exit 1; }
scripts/bundle.sh

dest=/Applications
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
if pgrep -x JustAnEQ >/dev/null; then
    osascript -e 'quit app id "cloud.hey-hi.just-an-eq"' 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x JustAnEQ >/dev/null || break; sleep 0.5; done
    pkill -x JustAnEQ 2>/dev/null || true
fi
rm -rf "$dest/JustAnEQ.app"
cp -R build/JustAnEQ.app "$dest/"
echo "Installed to $dest/JustAnEQ.app"
open "$dest/JustAnEQ.app"
