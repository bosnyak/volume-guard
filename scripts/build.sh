#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DRIVER_BUNDLE="$BUILD_DIR/VolumeGuard.driver"
APP_BUNDLE="$BUILD_DIR/VolumeGuard.app"

echo "==> [1/4] Building VolumeGuard Virtual HAL Driver (arm64 + x86_64)..."
rm -rf "$DRIVER_BUNDLE"
mkdir -p "$DRIVER_BUNDLE/Contents/MacOS"
cp "$ROOT_DIR/Driver/Info.plist" "$DRIVER_BUNDLE/Contents/Info.plist"

clang -arch arm64 -arch x86_64 \
    -bundle \
    -mmacosx-version-min=12.0 \
    -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter \
    -framework CoreFoundation -framework CoreAudio \
    "$ROOT_DIR/Driver/VolumeGuardDriver.c" \
    -o "$DRIVER_BUNDLE/Contents/MacOS/VolumeGuard"

codesign --force --sign - "$DRIVER_BUNDLE"

echo "==> [2/4] Building VolumeGuard Swift Menu Bar App (Universal arm64 + x86_64)..."
cd "$ROOT_DIR"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/VolumeGuard"

echo "==> [3/4] Packaging VolumeGuard.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/VolumeGuard"
cp -R "$DRIVER_BUNDLE" "$APP_BUNDLE/Contents/Resources/VolumeGuard.driver"
if [ -f "$ROOT_DIR/Assets/AppIcon.icns" ]; then
    cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>VolumeGuard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.volumeguard.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>VolumeGuard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

ENTITLEMENTS="$BUILD_DIR/VolumeGuard.entitlements"
cat > "$ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

echo "==> [4/4] Signing VolumeGuard.app..."
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

echo ""
echo "✅ Build complete!"
echo "   App Bundle:    $APP_BUNDLE"
echo "   HAL Driver:    $DRIVER_BUNDLE"
