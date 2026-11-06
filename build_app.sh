#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/Tiles.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [ -f "$ROOT/Assets/AppIcon.icns" ]; then
    cp "$ROOT/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

echo "Compiling Tiles macOS binary..."
swiftc \
  -module-cache-path /tmp/swift-module-cache \
  -O \
  -target arm64-apple-macosx14.0 \
  "$ROOT/Sources/Tiles/"*.swift \
  -o "$MACOS_DIR/Tiles"

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Tiles</string>
    <key>CFBundleIdentifier</key>
    <string>com.sagar.Tiles</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Tiles</string>
    <key>CFBundleDisplayName</key>
    <string>Tiles</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Tiles needs Accessibility access to read window positions across your displays and desktops and restore your saved layouts.</string>
</dict>
</plist>
EOF

# Pick a signing identity only if it is "Apple Development" or "Developer ID Application".
# Otherwise use ad-hoc signing with designated => identifier "com.sagar.Tiles" to preserve TCC permissions across rebuilds.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"(Apple Development|Developer ID Application)/{print $2; exit}')
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "Signing with certificate: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "com.sagar.Tiles" "$APP_DIR"
else
    codesign --force --deep --sign - --identifier "com.sagar.Tiles" -r='designated => identifier "com.sagar.Tiles"' "$APP_DIR"
fi
touch "$APP_DIR"
echo "Successfully built and signed: $APP_DIR"

if [ "${1:-}" = "--install" ]; then
    INSTALL_TARGET="$HOME/Applications/Tiles.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$INSTALL_TARGET"
    ditto "$APP_DIR" "$INSTALL_TARGET"
    touch "$INSTALL_TARGET"
    echo "Installed to: $INSTALL_TARGET"
fi
