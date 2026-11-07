#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/VolumeGuard.app"
VERSION="1.0.0"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/VolumeGuard-v${VERSION}-macOS.dmg"
ZIP_PATH="$BUILD_DIR/VolumeGuard-v${VERSION}-macOS.zip"

# 1. Build Universal Driver & App
"$ROOT_DIR/scripts/build.sh"

# 2. Create .zip archive for GitHub Releases
echo "==> Creating ZIP archive: $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# 3. Create .dmg installer with /Applications symlink
echo "==> Creating DMG installer: $DMG_PATH"
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/VolumeGuard.app"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "VolumeGuard" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$DMG_STAGING"

echo ""
echo "🎉 Release packages ready:"
echo "   📦 App Bundle:  $APP_BUNDLE"
echo "   💿 DMG Image:   $DMG_PATH"
echo "   🗜️  ZIP Archive: $ZIP_PATH"
