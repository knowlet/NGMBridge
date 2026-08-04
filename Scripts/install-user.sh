#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(bash "$ROOT/Scripts/build-app.sh")"
DEST="$HOME/Applications/NGMBridge.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed: $DEST"
