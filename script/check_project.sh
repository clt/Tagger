#!/usr/bin/env bash
set -euo pipefail

TAGGER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

CHECK_DIR="$(mktemp -d /tmp/tagger-xcodegen-check.XXXXXX)"
trap '/bin/rm -R "$CHECK_DIR"' EXIT

/bin/cp "$TAGGER_ROOT/project.yml" "$CHECK_DIR/project.yml"
/bin/cp -R "$TAGGER_ROOT/Tagger" "$CHECK_DIR/Tagger"
/bin/cp -R "$TAGGER_ROOT/TaggerTests" "$CHECK_DIR/TaggerTests"

xcodegen generate --spec "$CHECK_DIR/project.yml" --project "$CHECK_DIR" --quiet

/usr/bin/diff -q \
  "$TAGGER_ROOT/Tagger.xcodeproj/project.pbxproj" \
  "$CHECK_DIR/Tagger.xcodeproj/project.pbxproj"
/usr/bin/diff -q \
  "$TAGGER_ROOT/Tagger.xcodeproj/xcshareddata/xcschemes/Tagger.xcscheme" \
  "$CHECK_DIR/Tagger.xcodeproj/xcshareddata/xcschemes/Tagger.xcscheme"

echo "Tagger.xcodeproj matches project.yml."
