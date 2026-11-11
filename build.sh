#!/bin/zsh
set -eu
cd "${0:A:h}"

swift build -c release --arch arm64
SWIFT_BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
mkdir -p dist
BUILD_STAGE="$(mktemp -d "$PWD/dist/swift-build-XXXXXX")"
trap 'rm -rf "$BUILD_STAGE"' EXIT

LAUNCHER_APP="$BUILD_STAGE/TFT Live.app"
mkdir -p "$LAUNCHER_APP/Contents/MacOS" "$LAUNCHER_APP/Contents/Resources"
ICON_SET="$BUILD_STAGE/TFTLive.iconset"
mkdir -p "$ICON_SET"
for ICON_SIZE in 16 32 128 256 512; do
  sips -z "$ICON_SIZE" "$ICON_SIZE" Resources/TFTLive.png --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
  RETINA_SIZE=$((ICON_SIZE * 2))
  sips -z "$RETINA_SIZE" "$RETINA_SIZE" Resources/TFTLive.png --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o "$LAUNCHER_APP/Contents/Resources/TFTLive.icns"
cp "$SWIFT_BIN_DIR/TFTLive" "$LAUNCHER_APP/Contents/MacOS/TFT Live"
cp "$SWIFT_BIN_DIR/TFTLiveCLI" "$LAUNCHER_APP/Contents/MacOS/TFTLiveCLI"
cp "$SWIFT_BIN_DIR/SDKHost" "$LAUNCHER_APP/Contents/Resources/SDKHost"
codesign --force --sign - "$LAUNCHER_APP/Contents/Resources/SDKHost"
cp Resources/riot-sdk-host-override.json LICENSE THIRD_PARTY_NOTICES.md "$LAUNCHER_APP/Contents/Resources/"
cat > "$LAUNCHER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TFT Live</string>
<key>CFBundleIdentifier</key><string>local.tft.live.launcher</string>
<key>CFBundleName</key><string>TFT Live</string>
<key>CFBundleDisplayName</key><string>TFT Live</string>
<key>CFBundleIconFile</key><string>TFTLive.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>8</string>
<key>CFBundleShortVersionString</key><string>1.1.2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSRequiresNativeExecution</key><true/>
<key>LSArchitecturePriority</key><array><string>arm64</string></array>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$LAUNCHER_APP"
codesign --verify --deep --strict "$LAUNCHER_APP"
ditto -c -k --keepParent "$LAUNCHER_APP" "$BUILD_STAGE/TFT-Live-AppleSilicon.zip"
rm -rf 'dist/TFT Live.app'
mv "$LAUNCHER_APP" 'dist/TFT Live.app'
mv "$BUILD_STAGE/TFT-Live-AppleSilicon.zip" dist/TFT-Live-AppleSilicon.zip
(cd dist && shasum -a 256 TFT-Live-AppleSilicon.zip > TFT-Live-AppleSilicon.zip.sha256)
echo 'Built dist/TFT Live.app and dist/TFT-Live-AppleSilicon.zip'
