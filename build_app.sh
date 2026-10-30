#!/bin/zsh
set -euo pipefail

APP_DIR="/Users/sagar/Applications/Mac Apps/Tiles/Tiles.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [ -f "/Users/sagar/Applications/Mac Apps/Tiles/Assets/AppIcon.icns" ]; then
    cp "/Users/sagar/Applications/Mac Apps/Tiles/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

echo "Compiling Tiles universal macOS binary..."
swiftc \
  -module-cache-path /tmp/swift-module-cache \
  -O \
  -target arm64-apple-macosx14.0 \
  "/Users/sagar/Applications/Mac Apps/Tiles/Sources/Tiles/"*.swift \
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
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Sign using a stable bundle identifier requirement (or persistent dev certificate if present in Keychain)
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2; exit}')
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "Signing with Keychain certificate: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "com.sagar.Tiles" "$APP_DIR"
else
    codesign --force --deep --sign - --identifier "com.sagar.Tiles" -r='designated => identifier "com.sagar.Tiles"' "$APP_DIR"
fi
touch "$APP_DIR"
echo "Successfully built and signed: $APP_DIR"
