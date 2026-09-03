#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Tagger"
BUNDLE_ID="com.example.Tagger"
TAGGER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAGGER_XCODE_APP="${TAGGER_XCODE_APP:-/Applications/Xcode-beta.app}"
DERIVED_DATA="$TAGGER_ROOT/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ ! -d "$TAGGER_XCODE_APP" && -d /Applications/Xcode.app ]]; then
  TAGGER_XCODE_APP=/Applications/Xcode.app
fi

if [[ ! -d "$TAGGER_XCODE_APP" ]]; then
  echo "Xcode was not found. Set TAGGER_XCODE_APP to the installed Xcode app." >&2
  exit 1
fi

export DEVELOPER_DIR="$TAGGER_XCODE_APP/Contents/Developer"

cd "$TAGGER_ROOT"

if [[ ! -d Tagger.xcodeproj ]]; then
  ./script/generate_project.sh
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

/usr/bin/xcodebuild \
  -project Tagger.xcodeproj \
  -scheme Tagger \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 3
    if pgrep -x "$APP_NAME" >/dev/null; then
      exit 0
    fi
    echo "$APP_NAME did not stay running after launch." >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
