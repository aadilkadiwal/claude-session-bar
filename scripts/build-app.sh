#!/bin/bash
# Builds "Session Bar.app" into ./build from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product SessionBar
BIN="$(swift build -c release --show-bin-path)/SessionBar"

APP="build/Session Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SessionBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for a locally built app to run and to register "Open at login".
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
