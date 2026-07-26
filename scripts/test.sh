#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OkBrainMacOSAgent"
DEV_APP_NAME="$APP_NAME-Dev"
PROD_APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
DEV_APP_BUNDLE="$ROOT_DIR/dist/$DEV_APP_NAME.app"
PROD_APP_BINARY="$PROD_APP_BUNDLE/Contents/MacOS/$APP_NAME"
DEV_APP_BINARY="$DEV_APP_BUNDLE/Contents/MacOS/$DEV_APP_NAME"
PROD_INFO_PLIST="$PROD_APP_BUNDLE/Contents/Info.plist"
DEV_INFO_PLIST="$DEV_APP_BUNDLE/Contents/Info.plist"
PROD_APP_ICON="$PROD_APP_BUNDLE/Contents/Resources/$APP_NAME.icns"
DEV_APP_ICON="$DEV_APP_BUNDLE/Contents/Resources/$DEV_APP_NAME.icns"
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

section "Swift executable tests"
"$ROOT_DIR/.build/debug/PermissionRuleEngineTests"
"$ROOT_DIR/.build/debug/DisplayWakeTests"

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

section "Patch engine verifier"
PATCH_VERIFY_BINARY="$VERIFY_DIR/verify_patch_engine"
swiftc -target "$SWIFT_TARGET" -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${CORE_SOURCES[@]}" "$ROOT_DIR/scripts/verify_patch_engine.swift" -o "$PATCH_VERIFY_BINARY"
"$PATCH_VERIFY_BINARY"

section "Shell syntax checks"
while IFS= read -r script; do
  bash -n "$script"
done < <(find "$ROOT_DIR/scripts" -type f -name '*.sh' | sort)

section "App bundle build"
"$ROOT_DIR/scripts/build.sh" >/dev/null
"$ROOT_DIR/scripts/build.sh" --prod >/dev/null

section "App bundle contents"
test -d "$DEV_APP_BUNDLE"
test -x "$DEV_APP_BINARY"
test -f "$DEV_INFO_PLIST"
test -f "$DEV_APP_ICON"
/usr/bin/plutil -lint "$DEV_INFO_PLIST" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEV_INFO_PLIST")" = "com.okbrain.macos-agent.dev"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$DEV_INFO_PLIST")" = "OkBrainMacOSAgent-Dev"
test "$(/usr/libexec/PlistBuddy -c 'Print :AppEnvironment' "$DEV_INFO_PLIST")" = "dev"
test "$(/usr/libexec/PlistBuddy -c 'Print :AppStateDirectoryName' "$DEV_INFO_PLIST")" = ".okbrain-macos-agent-dev"
test -n "$(/usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$DEV_INFO_PLIST")"

test -d "$PROD_APP_BUNDLE"
test -x "$PROD_APP_BINARY"
test -f "$PROD_INFO_PLIST"
test -f "$PROD_APP_ICON"
/usr/bin/plutil -lint "$PROD_INFO_PLIST" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROD_INFO_PLIST")" = "com.okbrain.macos-agent"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PROD_INFO_PLIST")" = "OkBrainMacOSAgent"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROD_INFO_PLIST")" = "2.0.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :AppEnvironment' "$PROD_INFO_PLIST")" = "prod"
test "$(/usr/libexec/PlistBuddy -c 'Print :AppStateDirectoryName' "$PROD_INFO_PLIST")" = ".okbrain-macos-agent"
test -n "$(/usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$PROD_INFO_PLIST")"

echo "Tests passed"
