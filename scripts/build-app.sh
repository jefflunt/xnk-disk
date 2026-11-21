#!/usr/bin/env bash
set -euo pipefail

APP_NAME="XNK Disk"
APP_BUNDLE="dist/${APP_NAME}.app"
APP_VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo '0.1.0')"

rm -rf "dist/xnk-disk.app"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "Building native macOS binary (${APP_NAME} v${APP_VERSION})..."
go build -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" .

if [ -f "assets/AppIcon.icns" ]; then
  cp "assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>XNK Disk</string>
  <key>CFBundleExecutable</key>
  <string>XNK Disk</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.jefflunt.xnk-disk</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>XNK Disk</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

echo "Built ${APP_BUNDLE}"
ls -lh "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
