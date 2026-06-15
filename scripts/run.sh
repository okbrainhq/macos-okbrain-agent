#!/usr/bin/env bash
set -euo pipefail

MODE="run"
ENV="dev"
APP_BASENAME="OkBrainMacOSAgent"
PROD_BUNDLE_ID="com.okbrain.macos-agent"
DEV_BUNDLE_ID="com.okbrain.macos-agent.dev"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for arg in "$@"; do
  case "$arg" in
    --dev|dev)
      ENV="dev"
      ;;
    --prod|prod)
      ENV="prod"
      ;;
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
      MODE="$arg"
      ;;
    *)
      echo "usage: $0 [--dev|--prod] [run|--debug|--logs|--telemetry|--verify]" >&2
      exit 2
      ;;
  esac
done

if [[ "$ENV" == "dev" ]]; then
  APP_NAME="$APP_BASENAME-Dev"
  EXECUTABLE_NAME="$APP_BASENAME-Dev"
  BUNDLE_ID="$DEV_BUNDLE_ID"
else
  APP_NAME="$APP_BASENAME"
  EXECUTABLE_NAME="$APP_BASENAME"
  BUNDLE_ID="$PROD_BUNDLE_ID"
fi

APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

"$ROOT_DIR/scripts/build.sh" "--$ENV"

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

open_app() {
  if [[ "$ENV" == "dev" ]]; then
    /usr/bin/open -n "$APP_BUNDLE"
  else
    /usr/bin/open "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [--dev|--prod] [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
