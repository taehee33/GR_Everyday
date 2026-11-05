#!/bin/zsh
# Builds the sandboxed "GR Mac.app" (the App Store configuration) into ./build with Xcode.
# Double-click it to run. For an App Store upload use Xcode: Product → Archive.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project "GR Mac.xcodeproj" -scheme "GR Mac" -configuration Release \
    -derivedDataPath build/xcode -allowProvisioningUpdates -quiet build
rm -rf "build/GR Mac.app"
cp -R "build/xcode/Build/Products/Release/GR Mac.app" "build/GR Mac.app"
echo "built build/GR Mac.app"
