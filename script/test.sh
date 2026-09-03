#!/usr/bin/env bash
set -euo pipefail

TAGGER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAGGER_XCODE_APP="${TAGGER_XCODE_APP:-/Applications/Xcode-beta.app}"
DERIVED_DATA="$TAGGER_ROOT/.build/DerivedData"

if [[ ! -d "$TAGGER_XCODE_APP" && -d /Applications/Xcode.app ]]; then
  TAGGER_XCODE_APP=/Applications/Xcode.app
fi

if [[ ! -d "$TAGGER_XCODE_APP" ]]; then
  echo "Xcode was not found. Set TAGGER_XCODE_APP to the installed Xcode app." >&2
  exit 1
fi

export DEVELOPER_DIR="$TAGGER_XCODE_APP/Contents/Developer"

cd "$TAGGER_ROOT"

/usr/bin/xcodebuild \
  -project Tagger.xcodeproj \
  -scheme Tagger \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  test
