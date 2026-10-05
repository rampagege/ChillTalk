#!/bin/zsh
# Build a Release, package it as a DMG and create a GitHub release.
#
#   scripts/release.sh 0.1.0             # creates a DRAFT release (review it on GitHub, then publish)
#   scripts/release.sh 0.1.0 --publish   # publishes immediately
#   scripts/release.sh 0.1.0 --dry-run   # build + DMG only, no upload
#
# Builds are signed with the project's development team but NOT notarized, so users
# have to allow the app once in System Settings → Privacy & Security.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [--publish|--dry-run]}"
MODE="${2:-draft}"
TAG="v$VERSION"

cd "$(dirname "$0")/.."
[[ -z "$(git status --porcelain --untracked-files=no -- ChillTalk ChillTalk.xcodeproj)" ]] || { echo "✗ Commit your changes first"; exit 1; }

WORK="$(mktemp -d)"
BUILD_NUMBER="$(git rev-list --count HEAD)"

echo "▸ Building ChillTalk $VERSION ($BUILD_NUMBER)…"
# Universal binary so Intel Macs can run it too.
xcodebuild -project ChillTalk.xcodeproj -scheme ChillTalk -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$WORK/build" -allowProvisioningUpdates \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build -quiet

APP="$WORK/build/Build/Products/Release/ChillTalk.app"
codesign --verify --deep --strict "$APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/ChillTalk")" == *x86_64* ]] || { echo "✗ Not a universal binary"; exit 1; }

# DMG with the app next to an Applications shortcut: open it and drag one onto the other.
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ChillTalk.app"
ln -s /Applications "$STAGE/Applications"
DMG="$WORK/ChillTalk-$VERSION.dmg"
hdiutil create -volname "ChillTalk $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "▸ $DMG"
echo "  SHA-256 $SHA"

cat > "$WORK/notes.md" <<NOTES
## 安装 / Install

1. 下载 \`ChillTalk-$VERSION.dmg\`，打开后把 **ChillTalk** 拖到旁边的「应用程序」文件夹
2. 双击打开。本版本**未经苹果公证**，首次打开会提示无法验证开发者：
   打开 **系统设置 → 隐私与安全性**，在页面下方点 **仍要打开**
   （或在终端执行 \`xattr -dr com.apple.quarantine /Applications/ChillTalk.app\`）
3. 按提示授予**麦克风**和**辅助功能**权限，在设置里填写 API 密钥

Download the DMG, open it and drag **ChillTalk** onto Applications. This build is **not notarized**:
on first launch open **System Settings → Privacy & Security** and click **Open Anyway**.

需要 macOS 14 或更高版本 · Requires macOS 14+

SHA-256: \`$SHA\`
NOTES

if [[ "$MODE" == "--dry-run" ]]; then
  echo "✓ Dry run: $WORK"
  exit 0
fi

FLAGS=(--draft)
[[ "$MODE" == "--publish" ]] && FLAGS=()

# A stale GITHUB_TOKEN in the environment would override the keychain login.
env -u GITHUB_TOKEN gh release create "$TAG" "$DMG" --title "ChillTalk $VERSION" \
  --notes-file "$WORK/notes.md" --target "$(git rev-parse HEAD)" "${FLAGS[@]}"
echo "✓ Release $TAG created ($([[ ${#FLAGS[@]} -gt 0 ]] && echo draft || echo published))"
