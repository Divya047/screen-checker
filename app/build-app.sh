#!/bin/bash
# Builds the release binary and assembles the ScreenChecker.app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

BINARY=".build/release/ScreenChecker"
APP="build/ScreenChecker.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/ScreenChecker"
cp app/Info.plist "$APP/Contents/Info.plist"

# Stable signature: TCC (Screen Recording / Automation) binds to bundle id + Team ID.
# Ad-hoc ("-") has no Team ID, so every rebuild resets permissions.
# A real identity (even free "Apple Development") keeps the same Team ID,
# so rebuilds preserve granted permissions.
# Override with: CODESIGN_IDENTITY="Apple Development: ..." ./app/build-app.sh
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  # Auto-pick the first valid development/distribution identity, if any.
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -oE '"Apple Development[^"]*"|"Apple Distribution[^"]*"|"Developer ID[^"]*"' | head -1 | tr -d '"')"
  if [ -z "$CODESIGN_IDENTITY" ]; then
    CODESIGN_IDENTITY="-"
  fi
fi

if [ "$CODESIGN_IDENTITY" = "-" ]; then
  echo "Signing ad-hoc (permissions will reset on every rebuild)."
  codesign --force --sign - --timestamp=none "$APP"
else
  echo "Signing with identity: $CODESIGN_IDENTITY"
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP"
fi

echo "✅ Built $APP"
echo "First run:  open $APP"
echo "Then:        approve Screen Recording + Notifications, and the one-time"
echo "             Automation prompt the first time your browser is read."
