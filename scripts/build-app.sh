#!/bin/zsh
# Builds the sandboxed "GR Mac.app" (the App Store configuration) with Xcode and installs it
# in /Applications. Run it from there: macOS can't verify an app inside ~/Desktop, so Location
# permission (needed to join the camera Wi-Fi) never asks. App Store upload: Product → Archive.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project "GR Mac.xcodeproj" -scheme "GR Mac" -configuration Release \
    -derivedDataPath build/xcode -allowProvisioningUpdates -quiet build
# A running copy keeps its old signature while the file changes under it; quit it first.
osascript -e 'tell application "GR Mac" to quit' 2>/dev/null || true
while pgrep -f "/Applications/GR Mac.app/Contents/MacOS/" >/dev/null; do sleep 0.5; done
rm -rf "/Applications/GR Mac.app"
cp -R "build/xcode/Build/Products/Release/GR Mac.app" "/Applications/GR Mac.app"
echo "installed /Applications/GR Mac.app"
