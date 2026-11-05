#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(bash "$ROOT/Scripts/build-app.sh")"
DEST="$HOME/Applications/NGMBridge.app"
mkdir -p "$HOME/Applications"
# Finish copying before removing a working installation. Keep staging on the
# destination filesystem so the final move does not copy the bundle again.
STAGING="$(mktemp -d "$HOME/Applications/.NGMBridge-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/NGMBridge.app"
rm -rf "$DEST"
mv "$STAGING/NGMBridge.app" "$DEST"
open "$DEST"
echo "Installed: $DEST"
