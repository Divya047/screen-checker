#!/bin/bash
# One-shot setup: verify the opencode backend, build the app, launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "1/3 · opencode backend"
if ! command -v opencode >/dev/null 2>&1; then
  echo "❌ opencode not found on PATH."
  echo "   Install it first (https://opencode.ai), or set opencodeBinaryPath"
  echo "   in ~/Library/Application Support/ScreenChecker/config.json."
  exit 1
fi
echo "   found: $(command -v opencode)"

echo "2/3 · building"
./app/build-app.sh

echo "3/3 · launching"
open build/ScreenChecker.app

echo
echo "Next:"
echo "  • The agent file (.opencode/agents/screen-classifier.md) is written"
echo "    automatically into ~/Library/Application Support/ScreenChecker/"
echo "  • ScreenChecker starts in WARN-ONLY mode — check Today's report,"
echo "    then switch to Enforce from the menu bar when you trust it."
echo "  • Default monitoring slot: 12:00–13:00 weekdays (edit in Settings)."
