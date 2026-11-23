#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/NGMBridge.app"
STAGING=""
INCOMING=""
INCOMING_DIR=""
LOCK=""
LOCK_HELD=0
LOCK_TOKEN=""
LOCK_WAIT_LOGGED=0
INSTALLED=0
CLEANED=0

# Identity is the pid plus its start time. kill -0 is true for any live
# process that reused the pid, including a later installer, and the wait
# path would then block forever.
process_start() {
    local pid="$1"
    local token=""
    token="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | tr -s '[:space:]' ' ' || true)"
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    printf '%s' "$token"
}

identity_live() {
    local pid="$1"
    local expected="$2"
    local actual=""
    [[ "$pid" =~ ^[0-9]+$ && -n "$expected" ]] || return 1
    actual="$(process_start "$pid")"
    [[ -n "$actual" && "$actual" == "$expected" ]]
}

command_is_installer() {
    local pid="$1"
    local cmd=""
    [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] || return 1
    cmd="$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$cmd" == *install-user.sh* ]]
}

still_hold_lock() {
    local pid=""
    local token=""
    [[ "$LOCK_HELD" == 1 && -d "$LOCK" ]] || return 1
    pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    token="$(cat "$LOCK/started" 2>/dev/null || true)"
    [[ "$pid" == "$$" && -n "$LOCK_TOKEN" && "$token" == "$LOCK_TOKEN" ]]
}

require_lock() {
    if still_hold_lock; then
        return 0
    fi
    printf 'Lost the install lock.\n' >&2
    exit 1
}

note_lock_wait() {
    if [[ -n "${NGMBRIDGE_INSTALL_LOCK_WAIT_LOG:-}" && "$LOCK_WAIT_LOGGED" != 1 ]]; then
        printf '%s\n' "$$" >> "$NGMBRIDGE_INSTALL_LOCK_WAIT_LOG"
        LOCK_WAIT_LOGGED=1
    fi
}

# mkdir is the atomic claim. A directory we just created has no pid yet;
# leave it alone briefly so the owner can publish its identity. Never delete
# a renamed lock whose recorded process is still that same start time.
acquire_lock() {
    local pid=""
    local token=""
    local stale=""
    local unknown=0
    local age=0
    local now=0
    local mtime=0
    LOCK="$HOME/Applications/.NGMBridge-install.lock"
    while true; do
        if mkdir "$LOCK" 2>/dev/null; then
            printf '%s\n' "$$" > "$LOCK/pid" || true
            LOCK_TOKEN="$(process_start "$$")"
            if [[ -n "$LOCK_TOKEN" ]]; then
                printf '%s\n' "$LOCK_TOKEN" > "$LOCK/started" || true
            fi
            pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
            token="$(cat "$LOCK/started" 2>/dev/null || true)"
            if [[ "$pid" == "$$" && -n "$LOCK_TOKEN" && "$token" == "$LOCK_TOKEN" ]]; then
                LOCK_HELD=1
                return 0
            fi
            if [[ "$(cat "$LOCK/pid" 2>/dev/null || true)" == "$$" ]]; then
                rm -rf "$LOCK"
            fi
            printf 'Could not record the install lock identity.\n' >&2
            return 1
        fi
        if [[ -L "$LOCK" ]]; then
            pid="$(readlink "$LOCK" 2>/dev/null || true)"
            if command_is_installer "$pid"; then
                note_lock_wait
                sleep 0.1
                continue
            fi
            rm -f "$LOCK" || true
            if [[ -L "$LOCK" ]]; then
                unknown=$((unknown + 1))
                if [[ "$unknown" -ge 600 ]]; then
                    break
                fi
                sleep 0.1
            fi
            continue
        fi
        if [[ -d "$LOCK" ]]; then
            pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
            token="$(cat "$LOCK/started" 2>/dev/null || true)"
            if identity_live "$pid" "$token"; then
                note_lock_wait
                sleep 0.1
                continue
            fi
            if [[ ! -f "$LOCK/pid" ]]; then
                now="$(date +%s)"
                mtime="$(date -r "$LOCK" +%s 2>/dev/null || printf '0')"
                age=$((now - mtime))
                if [[ "$age" -lt 3 ]]; then
                    sleep 0.1
                    unknown=$((unknown + 1))
                    if [[ "$unknown" -ge 600 ]]; then
                        break
                    fi
                    continue
                fi
            fi
            stale="$LOCK.stale.$$.$unknown"
            if mv "$LOCK" "$stale" 2>/dev/null; then
                pid="$(cat "$stale/pid" 2>/dev/null || true)"
                token="$(cat "$stale/started" 2>/dev/null || true)"
                if identity_live "$pid" "$token"; then
                    if ! mv "$stale" "$LOCK" 2>/dev/null; then
                        printf 'Live install lock moved aside at: %s\n' "$stale" >&2
                        sleep 0.1
                    fi
                else
                    rm -rf "$stale"
                fi
                continue
            fi
        fi
        unknown=$((unknown + 1))
        if [[ "$unknown" -ge 600 ]]; then
            break
        fi
        sleep 0.1
    done
    printf 'Timed out waiting for another NGMBridge installer to finish.\n' >&2
    return 1
}

release_lock() {
    local pid=""
    local token=""
    if [[ "$LOCK_HELD" != 1 || -z "$LOCK" ]]; then
        LOCK_HELD=0
        return 0
    fi
    if [[ -d "$LOCK" ]]; then
        pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
        token="$(cat "$LOCK/started" 2>/dev/null || true)"
        if [[ "$pid" == "$$" && "$token" == "$LOCK_TOKEN" ]]; then
            rm -rf "$LOCK"
        fi
    fi
    LOCK_HELD=0
}

# A killed installer can leave the only copy of the previous app in staging.
# Recover that copy before replacing anything, then drop leftover temps.
recover_orphaned_backup() {
    local dir=""
    local base=""
    local previous=""
    shopt -s nullglob
    for dir in "$HOME/Applications"/.NGMBridge-install.*; do
        base="${dir##*/}"
        if [[ "$dir" == "$LOCK" || "$base" == .NGMBridge-install.lock ]]; then
            continue
        fi
        case "$base" in
            .NGMBridge-install.lock.stale.*)
                rm -rf "$dir" || true
                continue
                ;;
            .NGMBridge-install.incoming.*)
                rm -rf "$dir" || true
                continue
                ;;
        esac
        previous="$dir/previous.app"
        if [[ ! -e "$DEST" && ! -L "$DEST" && ( -e "$previous" || -L "$previous" ) ]]; then
            if mv "$previous" "$DEST"; then
                printf 'Restored an interrupted installation to: %s\n' "$DEST" >&2
            fi
        fi
        if [[ ! -e "$previous" && ! -L "$previous" ]]; then
            rm -rf "$dir" || true
        fi
    done
    shopt -u nullglob
}

# Publish src at dest. mv treats an existing directory as a container, nests
# the bundle inside it, and exits 0. macOS mv has no -T, and mv -n still
# nests when the leaf name is free.
move_into_place() {
    local src="$1"
    local dest="$2"
    local base=""
    local nested=""
    INCOMING_DIR="$(mktemp -d "$HOME/Applications/.NGMBridge-install.incoming.XXXXXX")"
    INCOMING="$INCOMING_DIR/NGMBridge.app"
    mv "$src" "$INCOMING" || return $?
    if [[ -e "$dest" || -L "$dest" ]]; then
        mv "$INCOMING" "$src" || true
        printf 'Destination already exists: %s\n' "$dest" >&2
        return 1
    fi
    mv -n "$INCOMING" "$dest" || true
    base="${INCOMING##*/}"
    nested="$dest/$base"
    if [[ -e "$nested" || -L "$nested" ]]; then
        mv "$nested" "$src" || true
        printf 'Refusing to nest the new app inside %s\n' "$dest" >&2
        return 1
    fi
    if [[ -e "$INCOMING" || -L "$INCOMING" ]]; then
        mv "$INCOMING" "$src" || true
        printf 'Destination already exists: %s\n' "$dest" >&2
        return 1
    fi
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

remove_incoming() {
    if [[ -z "$INCOMING_DIR" ]]; then
        return 0
    fi
    case "$INCOMING_DIR" in
        "$HOME/Applications/.NGMBridge-install.incoming."*)
            rm -rf "$INCOMING_DIR" || true
            ;;
    esac
    INCOMING_DIR=""
    INCOMING=""
}

# set +e is required: a failing cleanup command would otherwise skip the
# unlock. Safe to run again; the second call does not move the app twice.
cleanup() {
    status=$?
    if [[ "$CLEANED" == 1 ]]; then
        return "$status"
    fi
    CLEANED=1
    set +e
    if [[ "$INSTALLED" == 0 && -n "$STAGING" ]] && [[ -e "$STAGING/previous.app" || -L "$STAGING/previous.app" ]]; then
        if ! restore_previous; then
            printf 'Previous installation retained at: %s\n' "$STAGING/previous.app" >&2
        fi
    fi
    remove_incoming
    if should_remove_staging; then
        rm -rf "$STAGING" || true
    fi
    release_lock
    return "$status"
}

handle_signal() {
    trap - EXIT INT TERM HUP
    cleanup
    exit "$1"
}

mkdir -p "$HOME/Applications"
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
trap cleanup EXIT
acquire_lock || exit $?
require_lock
recover_orphaned_backup
require_lock
APP="$(bash "$ROOT/Scripts/build-app.sh")"
require_lock
# Finish copying before removing a working installation. Keep staging on the
# destination filesystem so the final move does not copy the bundle again.
STAGING="$(mktemp -d "$HOME/Applications/.NGMBridge-install.XXXXXX")"
cp -R "$APP" "$STAGING/NGMBridge.app"
require_lock
if [[ -e "$DEST" || -L "$DEST" ]]; then
    mv "$DEST" "$STAGING/previous.app"
fi
require_lock
if move_into_place "$STAGING/NGMBridge.app" "$DEST"; then
    INSTALLED=1
else
    exit $?
fi
open "$DEST"
echo "Installed: $DEST"
