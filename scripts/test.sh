#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OkBrainMacOSAgent"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_ICON="$APP_BUNDLE/Contents/Resources/$APP_NAME.icns"
SWIFTPM_CACHE="$ROOT_DIR/.build/swiftpm-cache"
SWIFTPM_FLAGS=(--disable-sandbox --cache-path "$SWIFTPM_CACHE")
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
TEST_HOME="$ROOT_DIR/.build/test-home"

cd "$ROOT_DIR"
mkdir -p "$SWIFTPM_CACHE"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
mkdir -p "$TEST_HOME"
export CLANG_MODULE_CACHE_PATH
export HOME="$TEST_HOME"

section() {
  printf '\n==> %s\n' "$1"
}

section "Swift package build"
swift build "${SWIFTPM_FLAGS[@]}" >/dev/null

section "Protocol verifier"
VERIFY_DIR="$ROOT_DIR/.build/verify"
VERIFY_BINARY="$VERIFY_DIR/verify_protocol"
mkdir -p "$VERIFY_DIR"
CORE_SOURCES=()
while IFS= read -r source; do
  CORE_SOURCES+=("$source")
done < <(find "$ROOT_DIR/Sources/OkBrainMacOSAgentCore" -type f -name '*.swift' | sort)
SWIFT_TARGET="$(uname -m)-apple-macosx14.0"
swiftc -target "$SWIFT_TARGET" -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${CORE_SOURCES[@]}" "$ROOT_DIR/scripts/verify_protocol.swift" -o "$VERIFY_BINARY"
"$VERIFY_BINARY"

section "Shell syntax checks"
while IFS= read -r script; do
  bash -n "$script"
done < <(find "$ROOT_DIR/scripts" -type f -name '*.sh' | sort)

section "App bundle build"
"$ROOT_DIR/scripts/build.sh" >/dev/null

section "App bundle contents"
test -d "$APP_BUNDLE"
test -x "$APP_BINARY"
test -f "$INFO_PLIST"
test -f "$APP_ICON"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" = "com.okbrain.macos-agent"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" = "2.0.0"

echo "Tests passed"
