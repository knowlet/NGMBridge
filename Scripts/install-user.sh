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

lock_fd() {
    if command -v flock >/dev/null 2>&1; then
        flock 9
        return $?
    fi
    if command -v perl >/dev/null 2>&1; then
        # flock(2) is tied to the open file description. Perl locks bash's fd 9
        # and exits; the lock stays until this shell closes fd 9.
        perl -e 'use Fcntl qw(:flock); open(my $fh, ">>&", 9) or die $!; flock($fh, LOCK_EX) or die $!;'
        return $?
    fi
    printf 'Need flock or perl to take the install lock.\n' >&2
    return 1
}

acquire_lock() {
    local legacy=""
    legacy="$HOME/Applications/.NGMBridge-install.lock"
    if [[ -L "$legacy" || -d "$legacy" ]]; then
        rm -rf "$legacy" || true
    fi
    LOCK_FILE="$HOME/Applications/.NGMBridge-install-lock"
    exec 9>>"$LOCK_FILE" || return 1
    note_lock_wait
    if ! lock_fd; then
        exec 9>&- || true
        return 1
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
        RENAMER="$(mktemp)"
        source="$(mktemp)"
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
        if ! "$compiler" -O2 -o "$RENAMER" "$source"; then
            rm -f "$source" "$RENAMER"
            RENAMER=""
            return 1
        fi
        rm -f "$source"
    fi
    "$RENAMER" "$src" "$dest"
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
        if [[ "$base" == .NGMBridge-install.lock ]]; then
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
            if rename_noreplace "$previous" "$DEST"; then
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
    INCOMING_DIR="$(mktemp -d "$HOME/Applications/.NGMBridge-install.incoming.XXXXXX")" || return $?
    INCOMING="$INCOMING_DIR/NGMBridge.app"
    mv "$src" "$INCOMING" || return $?
    if [[ -e "$dest" || -L "$dest" ]]; then
        mv "$INCOMING" "$src" || true
        printf 'Destination already exists: %s\n' "$dest" >&2
        return 1
    fi
    mv -n "$INCOMING" "$dest" || true
    # mv -n refuses when dest already contains this leaf, and leaves our
    # source in place. That existing leaf belongs to someone else.
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
