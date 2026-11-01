#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

app="build/JustAnEQ.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/JustAnEQ "$app/Contents/MacOS/JustAnEQ"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIdentifier</key>
    <string>cloud.hey-hi.just-an-eq</string>
    <key>CFBundleName</key>
    <string>JustAnEQ</string>
    <key>CFBundleDisplayName</key>
    <string>Just an EQ</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>CFBundleExecutable</key>
    <string>JustAnEQ</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Capture system audio to apply equalizer settings.</string>
</dict>
</plist>
PLIST
codesign --sign - --force build/JustAnEQ.app
