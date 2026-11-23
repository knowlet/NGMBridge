#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/NGMBridge.app"
STAGING=""
INCOMING=""
LOCK=""
LOCK_HELD=0
LOCK_WAIT_LOGGED=0
INSTALLED=0

# ln creates the lock symlink atomically. Wait while its pid is alive, and
# replace it only after that process has exited.
acquire_lock() {
    local pid=""
    local moved=""
    local stale=""
    local unknown=0
    LOCK="$HOME/Applications/.NGMBridge-install.lock"
    while true; do
        if ln -s "$$" "$LOCK" 2>/dev/null; then
            LOCK_HELD=1
            return 0
        fi
        pid=""
        if [[ -L "$LOCK" ]]; then
            pid="$(readlink "$LOCK" 2>/dev/null || true)"
        fi
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            if [[ -n "${NGMBRIDGE_INSTALL_LOCK_WAIT_LOG:-}" && "$LOCK_WAIT_LOGGED" != 1 ]]; then
                printf '%s\n' "$$" >> "$NGMBRIDGE_INSTALL_LOCK_WAIT_LOG"
                LOCK_WAIT_LOGGED=1
            fi
            sleep 0.1
            continue
        fi
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            stale="$LOCK.stale.$$.$unknown"
            if mv "$LOCK" "$stale" 2>/dev/null; then
                moved="$(readlink "$stale" 2>/dev/null || true)"
                if [[ "$moved" == "$pid" ]]; then
                    rm -f "$stale"
                elif ! mv "$stale" "$LOCK" 2>/dev/null; then
                    rm -f "$stale"
                fi
                continue
            fi
        fi
        unknown=$((unknown + 1))
        if [[ "$unknown" -ge 600 ]]; then
            printf 'Timed out waiting for another NGMBridge installer to finish.\n' >&2
            return 1
        fi
        sleep 0.1
    done
}

release_lock() {
    local target=""
    if [[ "$LOCK_HELD" != 1 || -z "$LOCK" ]]; then
        LOCK_HELD=0
        return 0
    fi
    if [[ -L "$LOCK" ]]; then
        target="$(readlink "$LOCK" 2>/dev/null || true)"
        if [[ "$target" == "$$" ]]; then
            rm -f "$LOCK"
        fi
    fi
    LOCK_HELD=0
}

# Publish src at dest. mv treats an existing directory as a container, nests
# the bundle inside it, and exits 0. macOS mv has no -T, and mv -n still
# nests when the leaf name is free. Rename via a sibling that does not exist,
# then refuse to leave the bundle inside an existing destination.
move_into_place() {
    local src="$1"
    local dest="$2"
    local base=""
    local nested=""
    INCOMING="$HOME/Applications/.NGMBridge-install.incoming.$$"
    if [[ -e "$INCOMING" || -L "$INCOMING" ]]; then
        printf 'Temporary install path already exists: %s\n' "$INCOMING" >&2
        return 1
    fi
    mv "$src" "$INCOMING" || return $?
    if [[ -e "$dest" || -L "$dest" ]]; then
        mv "$INCOMING" "$src" || true
        INCOMING=""
        printf 'Destination already exists: %s\n' "$dest" >&2
        return 1
    fi
    mv -n "$INCOMING" "$dest" || true
    base="${INCOMING##*/}"
    nested="$dest/$base"
    if [[ -e "$nested" || -L "$nested" ]]; then
        mv "$nested" "$src" || true
        INCOMING=""
        printf 'Refusing to nest the new app inside %s\n' "$dest" >&2
        return 1
    fi
    if [[ -e "$INCOMING" || -L "$INCOMING" ]]; then
        mv "$INCOMING" "$src" || true
        INCOMING=""
        printf 'Destination already exists: %s\n' "$dest" >&2
        return 1
    fi
    INCOMING=""
    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
        printf 'Failed to move the new app into place: %s\n' "$dest" >&2
        return 1
    fi
    if [[ ! -d "$dest/Contents" ]]; then
        printf 'Installed bundle is incomplete: %s\n' "$dest" >&2
        return 1
    fi
    return 0
}

restore_previous() {
    local displaced=""
    local attempt=0
    if [[ -e "$DEST" || -L "$DEST" ]]; then
        while [[ "$attempt" -lt 20 ]]; do
            displaced="$HOME/Applications/.NGMBridge-displaced.$$.$RANDOM"
            if [[ ! -e "$displaced" && ! -L "$displaced" ]]; then
                break
            fi
            displaced=""
            attempt=$((attempt + 1))
        done
        if [[ -z "$displaced" ]]; then
            return 1
        fi
        mv "$DEST" "$displaced" || return 1
        if [[ -e "$DEST" || -L "$DEST" || ( ! -e "$displaced" && ! -L "$displaced" ) ]]; then
            return 1
        fi
        printf 'Unexpected destination retained at: %s\n' "$displaced" >&2
    fi
    mv "$STAGING/previous.app" "$DEST" || return 1
    if [[ -e "$DEST/previous.app" || -L "$DEST/previous.app" ]]; then
        mv "$DEST/previous.app" "$STAGING/previous.app" || true
        return 1
    fi
    if [[ ! -e "$DEST" && ! -L "$DEST" ]]; then
        return 1
    fi
    return 0
}

should_remove_staging() {
    if [[ -z "$STAGING" ]]; then
        return 1
    fi
    case "$STAGING" in
        "$HOME/Applications/.NGMBridge-install."*)
            ;;
        *)
            return 1
            ;;
    esac
    if [[ "$INSTALLED" == 1 ]]; then
        return 0
    fi
    if [[ -e "$STAGING/previous.app" || -L "$STAGING/previous.app" ]]; then
        return 1
    fi
    return 0
}

cleanup() {
    status=$?
    if [[ "$INSTALLED" == 0 && -n "$STAGING" ]] && [[ -e "$STAGING/previous.app" || -L "$STAGING/previous.app" ]]; then
        if ! restore_previous; then
            printf 'Previous installation retained at: %s\n' "$STAGING/previous.app" >&2
        fi
    fi
    if [[ -n "$INCOMING" ]] && [[ -e "$INCOMING" || -L "$INCOMING" ]]; then
        case "$INCOMING" in
            "$HOME/Applications/.NGMBridge-install.incoming."*)
                rm -rf "$INCOMING"
                ;;
        esac
    fi
    if should_remove_staging; then
        rm -rf "$STAGING"
    fi
    release_lock
    return "$status"
}

mkdir -p "$HOME/Applications"
trap cleanup EXIT
acquire_lock || exit $?
APP="$(bash "$ROOT/Scripts/build-app.sh")"
# Finish copying before removing a working installation. Keep staging on the
# destination filesystem so the final move does not copy the bundle again.
STAGING="$(mktemp -d "$HOME/Applications/.NGMBridge-install.XXXXXX")"
cp -R "$APP" "$STAGING/NGMBridge.app"
if [[ -e "$DEST" || -L "$DEST" ]]; then
    mv "$DEST" "$STAGING/previous.app"
fi
if move_into_place "$STAGING/NGMBridge.app" "$DEST"; then
    INSTALLED=1
else
    exit $?
fi
open "$DEST"
echo "Installed: $DEST"
