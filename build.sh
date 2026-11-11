#!/bin/zsh
set -eu
cd "${0:A:h}"

swift build -c release --arch arm64
SWIFT_BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
mkdir -p dist
BUILD_STAGE="$(mktemp -d "$PWD/dist/swift-build-XXXXXX")"
trap 'rm -rf "$BUILD_STAGE"' EXIT

HOST_APP="$BUILD_STAGE/TFT SDK Host arm64.app"
mkdir -p "$HOST_APP/Contents/MacOS" "$HOST_APP/Contents/Frameworks"
cp "$SWIFT_BIN_DIR/SDKHost" "$HOST_APP/Contents/MacOS/SDKHost"
cat > "$HOST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SDKHost</string>
<key>CFBundleIdentifier</key><string>local.tft.live.sdk-host</string>
<key>CFBundleName</key><string>TFT SDK Host arm64</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSRequiresNativeExecution</key><true/>
<key>LSArchitecturePriority</key><array><string>arm64</string></array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$HOST_APP"
codesign --verify --deep --strict "$HOST_APP"
rm -rf 'TFT SDK Host arm64.app'
mv "$HOST_APP" 'TFT SDK Host arm64.app'
if [[ "${1:-}" == '--host-only' ]]; then exit 0; fi

LAUNCHER_APP="$BUILD_STAGE/TFT Live.app"
mkdir -p "$LAUNCHER_APP/Contents/MacOS" "$LAUNCHER_APP/Contents/Resources"
cp "$SWIFT_BIN_DIR/TFTLive" "$LAUNCHER_APP/Contents/MacOS/TFT Live"
cp "$SWIFT_BIN_DIR/TFTLiveCLI" "$LAUNCHER_APP/Contents/MacOS/TFTLiveCLI"
cp 'TFT SDK Host arm64.app/Contents/MacOS/SDKHost' "$LAUNCHER_APP/Contents/Resources/SDKHost"
cp riot-sdk-host-override.json LICENSE THIRD_PARTY_NOTICES.md "$LAUNCHER_APP/Contents/Resources/"
cat > "$LAUNCHER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TFT Live</string>
<key>CFBundleIdentifier</key><string>local.tft.live.launcher</string>
<key>CFBundleName</key><string>TFT Live</string>
<key>CFBundleDisplayName</key><string>TFT Live</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
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
rm -rf 'TFT Live.app.new'
if ! cp -cR 'dist/TFT Live.app' 'TFT Live.app.new'; then
  rm -rf 'TFT Live.app.new'
  cp -Rp 'dist/TFT Live.app' 'TFT Live.app.new'
fi
rm -rf 'TFT Live.app.previous'
if [[ -d 'TFT Live.app' ]]; then mv 'TFT Live.app' 'TFT Live.app.previous'; fi
mv 'TFT Live.app.new' 'TFT Live.app'
rm -rf 'TFT Live.app.previous'
echo 'Built dist/TFT Live.app and dist/TFT-Live-AppleSilicon.zip'
