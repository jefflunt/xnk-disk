#!/usr/bin/env bash
set -euo pipefail

APP_NAME="XNK Disk"
APP_BUNDLE="dist/${APP_NAME}.app"
APP_VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo '0.3.1')"

rm -rf "dist/xnk-disk.app" "dist/XNK Disk Native.app"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "Building native macOS binary (${APP_NAME} v${APP_VERSION})..."
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/xnk-clang-cache}" \
  swift build --disable-sandbox -c release \
  --cache-path /tmp/xnk-swiftpm-cache \
  --config-path /tmp/xnk-swiftpm-config \
  --security-path /tmp/xnk-swiftpm-sec

BIN_PATH="$(swift build --disable-sandbox -c release --show-bin-path --cache-path /tmp/xnk-swiftpm-cache --config-path /tmp/xnk-swiftpm-config --security-path /tmp/xnk-swiftpm-sec)/XnkDisk"
cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

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
  <string>${APP_NAME}</string>
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
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "Built ${APP_BUNDLE}"
ls -lh "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
