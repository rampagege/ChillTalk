#!/bin/zsh
# Build a Release, package it as a DMG and create a GitHub release.
#
#   scripts/release.sh 0.1.0             # creates a DRAFT release (review it on GitHub, then publish)
#   scripts/release.sh 0.1.0 --publish   # publishes immediately
#   scripts/release.sh 0.1.0 --dry-run   # build, DMG and appcast only, no upload
#
# What's new goes in docs/releases/<version>.md (Markdown). It heads the release notes and
# is shown in the app's update window.
#
# Builds are signed with the project's development team but NOT notarized, so users
# have to allow the app once in System Settings → Privacy & Security.
#
# In-app updates (Sparkle): the app reads appcast.xml from the latest release, so it's
# uploaded with every release, and the DMG is signed with the EdDSA key in the login
# keychain (account "ChillTalk"; its public half is SUPublicEDKey in Info.plist).
# On a new Mac, import a backup of the key first:
#   generate_keys --account ChillTalk -f <private-key-file>
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [--publish|--dry-run]}"
MODE="${2:-draft}"
TAG="v$VERSION"

cd "$(dirname "$0")/.."
[[ -z "$(git status --porcelain --untracked-files=no -- ChillTalk ChillTalk.xcodeproj)" ]] || { echo "✗ Commit your changes first"; exit 1; }
# Keep the project's version in step, so builds from Xcode or install.sh show the same number.
PROJECT_VERSION="$(sed -nE 's/.*MARKETING_VERSION = ([^;]+);.*/\1/p' ChillTalk.xcodeproj/project.pbxproj | head -1)"
[[ "$PROJECT_VERSION" == "$VERSION" ]] || { echo "✗ Project version is $PROJECT_VERSION: set MARKETING_VERSION to $VERSION in ChillTalk.xcodeproj and commit first"; exit 1; }

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

echo "▸ Signing the update…"
SPARKLE_BIN="$WORK/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' ChillTalk/Info.plist)"
[[ "$("$SPARKLE_BIN/generate_keys" --account ChillTalk -p 2>/dev/null)" == "$PUBLIC_KEY" ]] || {
  echo "✗ The keychain has no Sparkle key (account ChillTalk) matching SUPublicEDKey in Info.plist."
  echo "  Installed copies would reject this update. Import the key: generate_keys --account ChillTalk -f <file>"
  exit 1
}
ED_SIGNATURE="$("$SPARKLE_BIN/sign_update" --account ChillTalk "$DMG")"   # sparkle:edSignature="…" length="…"

# SUFeedURL is <repo>/releases/latest/download/appcast.xml
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' ChillTalk/Info.plist)"
RELEASES_URL="${FEED_URL%/latest/download/appcast.xml}"
[[ "$RELEASES_URL" != "$FEED_URL" ]] || { echo "✗ Unexpected SUFeedURL: $FEED_URL"; exit 1; }

NOTES_FILE="docs/releases/$VERSION.md"
if [[ -f "$NOTES_FILE" ]]; then
  WHATS_NEW="$(<"$NOTES_FILE")"
  [[ "$WHATS_NEW" != *']]>'* ]] || { echo "✗ $NOTES_FILE can't contain ]]>"; exit 1; }
  RELEASE_WHATS_NEW="## 更新内容 / What's new"$'\n\n'"$WHATS_NEW"$'\n\n'
else
  echo "⚠ No $NOTES_FILE: the update window will only link to the release page"
  WHATS_NEW="[更新内容 / What's new]($RELEASES_URL/tag/$TAG)"
  RELEASE_WHATS_NEW=""
fi

MIN_MACOS="$(sed -nE 's/.*MACOSX_DEPLOYMENT_TARGET = ([^;]+);.*/\1/p' ChillTalk.xcodeproj/project.pbxproj | head -1)"
# Only the newest release is listed: each release's appcast replaces the last one.
cat > "$WORK/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ChillTalk</title>
    <item>
      <title>ChillTalk $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
$WHATS_NEW
]]></description>
      <enclosure url="$RELEASES_URL/download/$TAG/ChillTalk-$VERSION.dmg" type="application/octet-stream" $ED_SIGNATURE/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$WORK/appcast.xml"
echo "▸ $WORK/appcast.xml"

cat > "$WORK/notes.md" <<NOTES
${RELEASE_WHATS_NEW}## 安装 / Install

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
env -u GITHUB_TOKEN gh release create "$TAG" "$DMG" "$WORK/appcast.xml" --title "ChillTalk $VERSION" \
  --notes-file "$WORK/notes.md" --target "$(git rev-parse HEAD)" "${FLAGS[@]}"
echo "✓ Release $TAG created ($([[ ${#FLAGS[@]} -gt 0 ]] && echo draft || echo published))"
