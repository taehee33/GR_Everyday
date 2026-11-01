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
# The icon file is named after its content: macOS caches app icons by file name, so a
# changed icon under the same name keeps showing the old one in the Dock and Finder.
ICON="AppIcon-$(shasum Resources/AppIcon.icns | cut -c1-8)"
cp Resources/AppIcon.icns "$APP/Contents/Resources/$ICON.icns"
# Stamp the build so Settings → 정보 shows exactly which source this app came from:
# build number = commit count, plus the commit and a mark for uncommitted changes.
PLIST="$APP/Contents/Info.plist"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
git diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT+수정됨"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $ICON" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :GRBuildCommit string $COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :GRBuildDate string $(date '+%Y-%m-%d %H:%M')" "$PLIST"
# Ad-hoc signature: enough for macOS to remember the Bluetooth permission.
codesign --force --sign - "$APP"
echo "built $APP"
