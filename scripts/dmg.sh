#!/bin/bash
# Builds build/JustAnEQ.dmg: the app plus an Applications link to drag it onto.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/bundle.sh

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R build/JustAnEQ.app "$stage/"
ln -s /Applications "$stage/Applications"
rm -f build/JustAnEQ.dmg
hdiutil create -volname "Just an EQ" -srcfolder "$stage" -format UDZO -quiet build/JustAnEQ.dmg
echo "build/JustAnEQ.dmg"
