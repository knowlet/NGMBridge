#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Keep stdout reserved for the app path consumed by install-user.sh.
swift build -c release --product NGMBridge >&2
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/.build/NGMBridge.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NGMBridge" "$APP/Contents/MacOS/NGMBridge"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/NGMBridge"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP"
fi

echo "$APP"
