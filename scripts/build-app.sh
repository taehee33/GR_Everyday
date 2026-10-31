#!/bin/zsh
# Builds "GR Mac.app" into ./build. Double-click it to run.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="build/GR Mac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GRLink "$APP/Contents/MacOS/GRLink"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature: enough for macOS to remember the Bluetooth permission.
codesign --force --sign - "$APP"
echo "built $APP"
