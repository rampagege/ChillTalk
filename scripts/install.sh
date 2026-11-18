#!/bin/zsh
# Build a Release copy of ChillTalk and install it to /Applications, so it runs
# without Xcode. Re-run after pulling changes to update.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d)/build"
APP_NAME="ChillTalk.app"
DEST="/Applications/$APP_NAME"

# Same numbering as release.sh: the latest release's version, the commit count as build number.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
BUILD_NUMBER="$(git rev-list --count HEAD)"

echo "▸ Building Release ${VERSION:-(no release tag)} ($BUILD_NUMBER)…"
xcodebuild -project ChillTalk.xcodeproj -scheme ChillTalk -configuration Release \
  -derivedDataPath "$BUILD_DIR" -allowProvisioningUpdates \
  ${VERSION:+MARKETING_VERSION=$VERSION} CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build -quiet

BUILT="$BUILD_DIR/Build/Products/Release/$APP_NAME"
[[ -d "$BUILT" ]] || { echo "✗ Build output not found: $BUILT"; exit 1; }

echo "▸ Installing to $DEST…"
# Quit a running copy first so the bundle can be replaced.
osascript -e 'tell application id "com.chilltalk.app" to quit' 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

echo "▸ Launching…"
open "$DEST"
echo "✓ Installed. ChillTalk now runs without Xcode."
