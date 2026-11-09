#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(bash "$ROOT/Scripts/build-app.sh")"
DEST="$HOME/Applications/NGMBridge.app"
mkdir -p "$HOME/Applications"
# Finish copying before removing a working installation. Keep staging on the
# destination filesystem so the final move does not copy the bundle again.
STAGING="$(mktemp -d "$HOME/Applications/.NGMBridge-install.XXXXXX")"
INSTALLED=0
cleanup() {
    status=$?
    if [[ "$INSTALLED" == 0 && ( -e "$STAGING/previous.app" || -L "$STAGING/previous.app" ) ]]; then
        if [[ -e "$DEST" || -L "$DEST" ]] || ! mv "$STAGING/previous.app" "$DEST"; then
            printf 'Previous installation retained at: %s\n' "$STAGING/previous.app" >&2
            return "$status"
        fi
    fi
    rm -rf "$STAGING"
    return "$status"
}
trap cleanup EXIT
cp -R "$APP" "$STAGING/NGMBridge.app"
if [[ -e "$DEST" || -L "$DEST" ]]; then
    mv "$DEST" "$STAGING/previous.app"
fi
mv "$STAGING/NGMBridge.app" "$DEST"
INSTALLED=1
open "$DEST"
echo "Installed: $DEST"
