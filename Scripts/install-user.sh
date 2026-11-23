#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/NGMBridge.app"
STAGING=""
INCOMING=""
INCOMING_DIR=""
LOCK_HELD=0
LOCK_WAIT_LOGGED=0
INSTALLED=0
CLEANED=0

# Advisory lock on one stable file. The file is never renamed, so two waiters
# cannot both decide the lock is stale and move a live owner's lock aside.
LOCK_FILE=""

note_lock_wait() {
    if [[ -n "${NGMBRIDGE_INSTALL_LOCK_WAIT_LOG:-}" && "$LOCK_WAIT_LOGGED" != 1 ]]; then
        printf '%s\n' "$$" >> "$NGMBRIDGE_INSTALL_LOCK_WAIT_LOG"
        LOCK_WAIT_LOGGED=1
    fi
}

process_start() {
    local pid="$1"
    local token=""
    token="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | tr -s '[:space:]' ' ' || true)"
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    printf '%s' "$token"
}

# The previous installer published either a symlink to its pid or a directory
# containing pid and start time. Do not remove that lock while that owner lives.
legacy_owner_alive() {
    local legacy="$1"
    local pid=""
    local token=""
    local actual=""
    local cmd=""
    if [[ -L "$legacy" ]]; then
        pid="$(readlink "$legacy" 2>/dev/null || true)"
        [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] || return 1
        cmd="$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null || true)"
        [[ "$cmd" == *install-user.sh* ]]
        return
    fi
    if [[ -d "$legacy" ]]; then
        pid="$(cat "$legacy/pid" 2>/dev/null || true)"
        token="$(cat "$legacy/started" 2>/dev/null || true)"
        [[ "$pid" =~ ^[0-9]+$ && -n "$token" ]] || return 1
        actual="$(process_start "$pid")"
        [[ -n "$actual" && "$actual" == "$token" ]]
        return
    fi
    return 1
}

lock_fd() {
    local mode="${1:-block}"
    if command -v flock >/dev/null 2>&1; then
        if [[ "$mode" == nonblock ]]; then
            flock -n 9
        else
            flock 9
        fi
        return $?
    fi
    if command -v perl >/dev/null 2>&1; then
        if [[ "$mode" == nonblock ]]; then
            perl -e 'use Fcntl qw(:flock); open(my $fh, ">>&", 9) or die $!; exit(flock($fh, LOCK_EX|LOCK_NB) ? 0 : 1);'
        else
            perl -e 'use Fcntl qw(:flock); open(my $fh, ">>&", 9) or die $!; flock($fh, LOCK_EX) or die $!;'
        fi
        return $?
    fi
    printf 'Need flock or perl to take the install lock.\n' >&2
    return 1
}

# Publish pid and start time in one rename so an older installer never sees a
# half-written directory and treats it as stale. Held until this install exits.
LEGACY_LOCK=""
LEGACY_TOKEN=""

publish_legacy_lock() {
    local legacy="$1"
    local tmp=""
    LEGACY_TOKEN="$(process_start "$$")"
    if [[ -z "$LEGACY_TOKEN" ]]; then
        printf 'Could not read the installer start time.\n' >&2
        return 1
    fi
    tmp="$(mktemp -d "$HOME/Applications/.NGMBridge-legacy.XXXXXX")" || return 1
    printf '%s\n' "$$" > "$tmp/pid" || { rm -rf "$tmp"; return 1; }
    printf '%s\n' "$LEGACY_TOKEN" > "$tmp/started" || { rm -rf "$tmp"; return 1; }
    # Use the real mv. A test stub on PATH must not block lock publication.
    if /bin/mv -nT "$tmp" "$legacy" 2>/dev/null; then
        LEGACY_LOCK="$legacy"
        return 0
    fi
    if [[ -e "$tmp" || -L "$tmp" ]]; then
        if [[ ! -e "$legacy" && ! -L "$legacy" ]]; then
            if /bin/mv "$tmp" "$legacy"; then
                LEGACY_LOCK="$legacy"
                return 0
            fi
        fi
        rm -rf "$tmp" || true
    fi
    return 1
}

release_legacy_lock() {
    local legacy="$HOME/Applications/.NGMBridge-install.lock"
    local pid=""
    local token=""
    if [[ -z "$LEGACY_LOCK" ]]; then
        return 0
    fi
    if [[ -d "$legacy" && ! -L "$legacy" ]]; then
        pid="$(cat "$legacy/pid" 2>/dev/null || true)"
        token="$(cat "$legacy/started" 2>/dev/null || true)"
        if [[ "$pid" == "$$" && "$token" == "$LEGACY_TOKEN" ]]; then
            rm -rf "$legacy" || true
        fi
    fi
    LEGACY_LOCK=""
}

acquire_lock() {
    local legacy=""
    local misses=0
    legacy="$HOME/Applications/.NGMBridge-install.lock"
    while true; do
        if [[ -L "$legacy" || -d "$legacy" ]]; then
            misses=0
            if legacy_owner_alive "$legacy"; then
                sleep 0.1
                continue
            fi
            rm -rf "$legacy" || true
            if [[ -L "$legacy" || -d "$legacy" ]]; then
                printf 'Could not remove a stale legacy install lock: %s\n' "$legacy" >&2
                return 1
            fi
            continue
        fi
        if publish_legacy_lock "$legacy"; then
            break
        fi
        misses=$((misses + 1))
        if [[ "$misses" -ge 50 ]]; then
            printf 'Could not publish the legacy install lock.\n' >&2
            return 1
        fi
        sleep 0.05
    done
    LOCK_FILE="$HOME/Applications/.NGMBridge-install-lock"
    if ! exec 9>>"$LOCK_FILE"; then
        release_legacy_lock
        return 1
    fi
    if ! lock_fd nonblock; then
        note_lock_wait
        if ! lock_fd block; then
            exec 9>&- || true
            release_legacy_lock
            return 1
        fi
    fi
    LOCK_HELD=1
    return 0
}

require_lock() {
    if [[ "$LOCK_HELD" == 1 ]]; then
        return 0
    fi
    printf 'Lost the install lock.\n' >&2
    exit 1
}

release_lock() {
    release_legacy_lock
    if [[ "$LOCK_HELD" != 1 ]]; then
        LOCK_HELD=0
        return 0
    fi
    exec 9>&- || true
    LOCK_HELD=0
}

# Rename src onto dest. Fail, leaving src in place, when dest exists.
# GNU mv -nT does this. macOS mv has no -T and mv -n still nests into a directory.
RENAMER=""
rename_noreplace() {
    local src="$1"
    local dest="$2"
    local err=""
    local status=0
    local base=""
    err="$(mv -nT "$src" "$dest" 2>&1)" && return 0
    status=$?
    if [[ ! -e "$src" && ! -L "$src" ]]; then
        base="${src##*/}"
        if [[ -e "$dest/$base" || -L "$dest/$base" ]]; then
            mv "$dest/$base" "$src" || true
        fi
        return "$status"
    fi
    case "$err" in
        *illegal\ option*|*invalid\ option*|*unrecognized\ option*)
            rename_noreplace_fallback "$src" "$dest"
            return $?
            ;;
    esac
    return "$status"
}

c_source_temp() {
    local path=""
    if path="$(mktemp -x .c "${TMPDIR:-/tmp}/ngmbridge-rename.XXXXXX" 2>/dev/null)"; then
        printf '%s\n' "$path"
        return 0
    fi
    if path="$(mktemp --suffix=.c "${TMPDIR:-/tmp}/ngmbridge-rename.XXXXXX" 2>/dev/null)"; then
        printf '%s\n' "$path"
        return 0
    fi
    path="$(mktemp "${TMPDIR:-/tmp}/ngmbridge-rename.XXXXXX.c")" || return 1
    printf '%s\n' "$path"
}

rename_noreplace_fallback() {
    local src="$1"
    local dest="$2"
    local compiler=""
    local source=""
    if [[ -z "$RENAMER" ]]; then
        compiler="$(command -v clang || true)"
        if [[ -z "$compiler" ]]; then
            compiler="$(command -v cc || true)"
        fi
        if [[ -z "$compiler" ]]; then
            printf 'Cannot rename exclusively without mv -T or a C compiler.\n' >&2
            return 1
        fi
        RENAMER="$(mktemp "${TMPDIR:-/tmp}/ngmbridge-rename.XXXXXX")"
        source="$(c_source_temp)" || return 1
        cat > "$source" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#if defined(__APPLE__)
int renamex_np(const char *from, const char *to, unsigned int flags);
#ifndef RENAME_EXCL
#define RENAME_EXCL 0x00000004u
#endif
#else
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1u << 0)
#endif
#endif
int main(int argc, char **argv) {
    if (argc != 3) {
        return 2;
    }
#if defined(__APPLE__)
    if (renamex_np(argv[1], argv[2], RENAME_EXCL) != 0) {
#else
    if (renameat2(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_NOREPLACE) != 0) {
#endif
        fprintf(stderr, "rename: %s\n", strerror(errno));
        return 1;
    }
    return 0;
}
EOF
        # Apple clang treats a suffixless file as a linker input. -x c forces C.
        if ! "$compiler" -x c -O2 -o "$RENAMER" "$source"; then
            rm -f "$source" "$RENAMER"
            RENAMER=""
            return 1
        fi
        rm -f "$source"
    fi
    "$RENAMER" "$src" "$dest"
}

# Only directories this installer creates. A name such as
# .NGMBridge-install.backup is user data even when the suffix is six letters.
staging_temp_name() {
    [[ "$1" =~ ^\.NGMBridge-install\.[A-Za-z0-9_]{6}$ ]]
}

incoming_temp_name() {
    [[ "$1" =~ ^\.NGMBridge-install\.incoming\.[A-Za-z0-9_]{6}$ ]]
}

stale_lock_temp_name() {
    [[ "$1" =~ ^\.NGMBridge-install\.lock\.stale\.[0-9]+\.[0-9]+$ ]]
}

# True when every entry is an artifact this installer writes, and there is
# at least one. Empty directories and user files are not installer temps.
installer_payload_only() {
    local dir="$1"
    local allowed="$2"
    local entry=""
    local base=""
    local any=0
    local nullglob_state=""
    nullglob_state="$(shopt -p nullglob)"
    shopt -s nullglob dotglob
    for entry in "$dir"/*; do
        any=1
        base="${entry##*/}"
        case ":${allowed}:" in
            *":${base}:"*) ;;
            *)
                shopt -u dotglob
                eval "$nullglob_state"
                return 1
                ;;
        esac
    done
    shopt -u dotglob
    eval "$nullglob_state"
    [[ "$any" == 1 ]]
}

# A killed installer can leave the only copy of the previous app in staging.
# Restore that copy, then remove only directories this installer created.
recover_orphaned_backup() {
    local dir=""
    local base=""
    local previous=""
    local verified=0
    shopt -s nullglob
    for dir in "$HOME/Applications"/.NGMBridge-install.*; do
        # A symlink can point at a directory outside Applications. Never follow it.
        if [[ -L "$dir" || ! -d "$dir" ]]; then
            continue
        fi
        base="${dir##*/}"
        verified=0
        if [[ -f "$dir/.ngmbridge-installer" && ! -L "$dir/.ngmbridge-installer" ]]; then
            if incoming_temp_name "$base" && installer_payload_only "$dir" "NGMBridge.app:.ngmbridge-installer"; then
                rm -rf "$dir" || true
                continue
            fi
            if stale_lock_temp_name "$base" && installer_payload_only "$dir" "pid:started:.ngmbridge-installer"; then
                rm -rf "$dir" || true
                continue
            fi
            if staging_temp_name "$base" && installer_payload_only "$dir" "NGMBridge.app:previous.app:.ngmbridge-installer"; then
                verified=1
            fi
        fi
        previous="$dir/previous.app"
        if [[ "$verified" == 1 && ! -e "$DEST" && ! -L "$DEST" && ( -e "$previous" || -L "$previous" ) ]]; then
            if rename_noreplace "$previous" "$DEST"; then
                printf 'Restored an interrupted installation to: %s\n' "$DEST" >&2
            fi
        fi
        if [[ "$verified" == 1 && ! -e "$previous" && ! -L "$previous" ]]; then
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
    INCOMING_DIR="$(mktemp -d "$HOME/Applications/.NGMBridge-install.incoming.XXXXXX")" || return $?
    : > "$INCOMING_DIR/.ngmbridge-installer" || return $?
    INCOMING="$INCOMING_DIR/NGMBridge.app"
    mv "$src" "$INCOMING" || return $?
    if [[ -e "$dest" || -L "$dest" ]]; then
        mv "$INCOMING" "$src" || true
        printf 'Destination already exists: %s\n' "$dest" >&2
        return 1
    fi
    mv -n "$INCOMING" "$dest" || return $?
    # mv -n can also exit 0 on macOS while leaving the source in place when
    # the destination already contains this leaf. That leaf is not ours.
    if [[ -e "$INCOMING" || -L "$INCOMING" ]]; then
        printf 'Destination already exists: %s\n' "$dest" >&2
        return 1
    fi
    base="${INCOMING##*/}"
    nested="$dest/$base"
    if [[ -e "$nested" || -L "$nested" ]]; then
        mv "$nested" "$src" || true
        printf 'Refusing to nest the new app inside %s\n' "$dest" >&2
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
    if ! rename_noreplace "$STAGING/previous.app" "$DEST"; then
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
: > "$STAGING/.ngmbridge-installer"
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
