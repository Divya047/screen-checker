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

# Ad-hoc signature: TCC (permissions) binds to the bundle id + signature.
# Rebuilds re-sign, so macOS may ask again for Screen Recording after updates.
codesign --force --sign - --timestamp=none "$APP"

echo "✅ Built $APP"
echo "First run:  open $APP"
echo "Then:        approve Screen Recording + Notifications, and the one-time"
echo "             Automation prompt the first time your browser is read."
