#!/usr/bin/env bash
set -euo pipefail

APP_BASENAME="OkBrainMacOSAgent"
EXECUTABLE_TARGET="OkBrainMacOSAgent"
PROD_BUNDLE_ID="com.okbrain.macos-agent"
DEV_BUNDLE_ID="com.okbrain.macos-agent.dev"
CERT_NAME="OkBrain Dev"
OKBRAIN_KEYCHAIN="$HOME/Library/Keychains/okbrain.keychain-db"
OKBRAIN_KEYCHAIN_PASS="okbrain"
MENU_BAR_SYMBOL="brain.head.profile"
WEBP_VERSION="1.5.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
PROD_PLIST="$ROOT_DIR/Info.plist"
DEV_PLIST="$ROOT_DIR/Info-Dev.plist"
SWIFTPM_CACHE="$ROOT_DIR/.build/swiftpm-cache"
SWIFTPM_FLAGS=(--disable-sandbox --cache-path "$SWIFTPM_CACHE")
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
ENV="dev"

for arg in "$@"; do
  case "$arg" in
    --dev|dev)
      ENV="dev"
      ;;
    --prod|prod)
      ENV="prod"
      ;;
    *)
      echo "usage: $0 [--dev|--prod]" >&2
      exit 2
      ;;
  esac
done

if [[ "$ENV" == "dev" ]]; then
  APP_NAME="$APP_BASENAME-Dev"
  EXECUTABLE_NAME="$APP_BASENAME-Dev"
  BUNDLE_ID="$DEV_BUNDLE_ID"
  SOURCE_PLIST="$DEV_PLIST"
else
  APP_NAME="$APP_BASENAME"
  EXECUTABLE_NAME="$APP_BASENAME"
  BUNDLE_ID="$PROD_BUNDLE_ID"
  SOURCE_PLIST="$PROD_PLIST"
fi

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="$APP_NAME.icns"
APP_ICON="$APP_RESOURCES/$APP_ICON_NAME"

cd "$ROOT_DIR"
mkdir -p "$SWIFTPM_CACHE" "$CLANG_MODULE_CACHE_PATH"
export CLANG_MODULE_CACHE_PATH
swift build "${SWIFTPM_FLAGS[@]}"
BUILD_BINARY="$(swift build "${SWIFTPM_FLAGS[@]}" --show-bin-path)/$EXECUTABLE_TARGET"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$SOURCE_PLIST" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $APP_ICON_NAME" "$INFO_PLIST"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
/usr/bin/swift "$ROOT_DIR/scripts/generate_app_icon.swift" "$APP_ICON" "$MENU_BAR_SYMBOL"

case "$(uname -m)" in
  arm64) WEBP_ARCH="mac-arm64" ;;
  x86_64) WEBP_ARCH="mac-x86-64" ;;
  *) WEBP_ARCH="" ;;
esac

VENDORED_CWEBP=""
if [[ -n "$WEBP_ARCH" ]]; then
  VENDORED_CWEBP="$ROOT_DIR/vendor/libwebp/$WEBP_VERSION/$WEBP_ARCH/bin/cwebp"
fi

CWEBP_SOURCE="${MACOS_AGENT_CWEBP_PATH:-}"
if [[ -z "$CWEBP_SOURCE" && -n "$VENDORED_CWEBP" && -x "$VENDORED_CWEBP" ]]; then
  CWEBP_SOURCE="$VENDORED_CWEBP"
fi

if [[ -n "$CWEBP_SOURCE" && -x "$CWEBP_SOURCE" ]]; then
  cp "$CWEBP_SOURCE" "$APP_RESOURCES/cwebp"
  chmod +x "$APP_RESOURCES/cwebp"
  echo "Bundled cwebp from $CWEBP_SOURCE"
else
  echo "Warning: cwebp not bundled; expected $VENDORED_CWEBP or set MACOS_AGENT_CWEBP_PATH."
fi

find_okbrain_identity() {
  local keychain="${1:-}"

  if [[ -n "$keychain" ]]; then
    security find-identity -v -p codesigning "$keychain" 2>/dev/null
  else
    security find-identity -v -p codesigning 2>/dev/null
  fi | awk -v name="$CERT_NAME" '
    $2 ~ /^[[:xdigit:]]{40}$/ && index($0, "\"" name "\"") { print $2; exit }
  '
}

CODESIGN_IDENTITY=""
CODESIGN_KEYCHAIN_ARGS=()

if [[ -f "$OKBRAIN_KEYCHAIN" ]]; then
  security unlock-keychain -p "$OKBRAIN_KEYCHAIN_PASS" "$OKBRAIN_KEYCHAIN" 2>/dev/null || true
  security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$OKBRAIN_KEYCHAIN_PASS" "$OKBRAIN_KEYCHAIN" >/dev/null 2>&1 || true

  CODESIGN_IDENTITY="$(find_okbrain_identity "$OKBRAIN_KEYCHAIN" || true)"
  if [[ -n "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_KEYCHAIN_ARGS=(--keychain "$OKBRAIN_KEYCHAIN")
  fi
fi

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(find_okbrain_identity || true)"
fi

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  if codesign --force --deep "${CODESIGN_KEYCHAIN_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"; then
    if codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
      echo "Signed $APP_BUNDLE with $CERT_NAME ($CODESIGN_IDENTITY)"
    else
      echo "Built $APP_BUNDLE (signed but verification failed — run scripts/setup-codesign.sh)"
    fi
  else
    echo "Built $APP_BUNDLE (unsigned — codesign could not access $CERT_NAME; run scripts/setup-codesign.sh)"
  fi
else
  echo "Built $APP_BUNDLE (unsigned — run scripts/setup-codesign.sh to enable persistent permissions)"
fi

echo "Built $APP_BUNDLE (env=$ENV)"
