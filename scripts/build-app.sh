#!/bin/zsh
# Builds the sandboxed "GR Everyday.app" (the App Store configuration) with Xcode and installs it
# in /Applications. Run it from there: macOS can't verify an app inside ~/Desktop, so Location
# permission (needed to join the camera Wi-Fi) never asks. App Store upload: Product → Archive.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project "GR Mac.xcodeproj" -scheme "GR Mac" -configuration Release \
    -derivedDataPath build/xcode -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build
# A running copy keeps its old signature while the file changes under it; quit it first.
# (Earlier builds were "GR Mac.app", bundle id com.hantaehee.grconnect; that copy is left alone.)
osascript -e 'tell application "GR Everyday" to quit' 2>/dev/null || true
while pgrep -f "/Applications/GR Everyday.app/Contents/MacOS/" >/dev/null; do sleep 0.5; done
rm -rf "/Applications/GR Everyday.app"
cp -R "build/xcode/Build/Products/Release/GR Everyday.app" "/Applications/GR Everyday.app"
echo "installed /Applications/GR Everyday.app"
