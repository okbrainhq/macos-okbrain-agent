#!/usr/bin/env bash
set -euo pipefail

APP_NAME="OkBrainMacOSAgent"
BUNDLE_ID="com.okbrain.macos-agent"
MIN_SYSTEM_VERSION="14.0"
VERSION="1.0.0"
BUILD="1"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="$APP_NAME.icns"
APP_ICON="$APP_RESOURCES/$APP_ICON_NAME"
MENU_BAR_SYMBOL="brain.head.profile"
SWIFTPM_CACHE="$ROOT_DIR/.build/swiftpm-cache"
SWIFTPM_FLAGS=(--disable-sandbox --cache-path "$SWIFTPM_CACHE")
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"

cd "$ROOT_DIR"
mkdir -p "$SWIFTPM_CACHE"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
export CLANG_MODULE_CACHE_PATH
swift build "${SWIFTPM_FLAGS[@]}"
BUILD_BINARY="$(swift build "${SWIFTPM_FLAGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
/usr/bin/swift "$ROOT_DIR/scripts/generate_app_icon.swift" "$APP_ICON" "$MENU_BAR_SYMBOL"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built $APP_BUNDLE"
