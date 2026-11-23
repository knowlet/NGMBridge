#!/bin/bash
set -euo pipefail

# Reproduce the installer race without Swift, signing, Launch Services, or the real HOME.
# Plain mv nests a directory into an existing destination and still exits 0.
# The installer must not treat that as success.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
pid_a=""
pid_b=""
cleanup_test() {
    status=$?
    if [[ -n "$pid_a" ]]; then
        kill "$pid_a" 2>/dev/null || true
        wait "$pid_a" 2>/dev/null || true
    fi
    if [[ -n "$pid_b" ]]; then
        kill "$pid_b" 2>/dev/null || true
        wait "$pid_b" 2>/dev/null || true
    fi
    rm -rf "$TEMP"
    return "$status"
}
trap cleanup_test EXIT

wait_pid() {
    local p="$1"
    local ticks=0
    while kill -0 "$p" 2>/dev/null; do
        if [[ "$ticks" -ge 200 ]]; then
            kill "$p" 2>/dev/null || true
            wait "$p" 2>/dev/null || true
            return 1
        fi
        sleep 0.05
        ticks=$((ticks + 1))
    done
    wait "$p" || return $?
}

FIXTURE_ROOT="$TEMP/project with spaces"
mkdir -p "$FIXTURE_ROOT/Scripts" "$FIXTURE_ROOT/Resources" "$FIXTURE_ROOT/bin" \
    "$FIXTURE_ROOT/.build/bin" "$TEMP/home with spaces/Applications"
cp "$ROOT/Scripts/build-app.sh" "$ROOT/Scripts/install-user.sh" "$FIXTURE_ROOT/Scripts/"
printf 'fixture plist\n' > "$FIXTURE_ROOT/Resources/Info.plist"
printf 'fixture binary, never executed\n' > "$FIXTURE_ROOT/.build/bin/NGMBridge"

cat > "$FIXTURE_ROOT/bin/swift" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ "$*" == "build -c release --show-bin-path" ]]; then
    printf '%s\n' "$FIXTURE_ROOT/.build/bin"
elif [[ "$*" == "build -c release --product NGMBridge" ]]; then
    printf 'Building for production...\n'
    printf 'fixture diagnostic\n' >&2
    exit "${FIXTURE_BUILD_STATUS:-0}"
else
    printf 'Unexpected swift arguments\n' >&2
    exit 99
fi
STUB
cat > "$FIXTURE_ROOT/bin/codesign" <<'STUB'
#!/bin/bash
printf 'fixture signing diagnostic\n' >&2
STUB
cat > "$FIXTURE_ROOT/bin/open" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$FIXTURE_OPEN_LOG"
STUB
chmod +x "$FIXTURE_ROOT/bin/"*
export FIXTURE_ROOT
export PATH="$FIXTURE_ROOT/bin:/usr/bin:/bin"
export HOME="$TEMP/home with spaces"
export FIXTURE_OPEN_LOG="$TEMP/open.log"
DEST="$HOME/Applications/NGMBridge.app"
export DEST

demo="$TEMP/mv-nest"
mkdir -p "$demo/NGMBridge.app" "$demo/existing.app"
printf 'bundle\n' > "$demo/NGMBridge.app/marker"
/bin/mv "$demo/NGMBridge.app" "$demo/existing.app"
[[ -f "$demo/existing.app/NGMBridge.app/marker" ]]
printf 'PASS: mv nests a bundle into an existing destination and exits 0\n'

dead=2147483646
while kill -0 "$dead" 2>/dev/null; do
    dead=$((dead - 1))
    if [[ "$dead" -lt 2 ]]; then
        printf 'could not find an unused pid\n' >&2
        exit 1
    fi
done
ln -s "$dead" "$HOME/Applications/.NGMBridge-install.lock"
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/stale.stdout" 2> "$TEMP/stale.stderr"
[[ "$(cat "$TEMP/stale.stdout")" == "Installed: $DEST" ]]
[[ -f "$DEST/Contents/MacOS/NGMBridge" ]]
[[ ! -e "$HOME/Applications/.NGMBridge-install.lock" ]]
[[ -z "$(find "$HOME/Applications" -name '.NGMBridge-install.*' -print)" ]]
printf 'PASS: a dead installer lock does not block a later install\n'

rm -rf "$DEST" "$HOME/Applications/.NGMBridge-install.lock"
mkdir -p "$HOME/Applications/.NGMBridge-install.lock"
printf '%s\n' "$$" > "$HOME/Applications/.NGMBridge-install.lock/pid"
printf '%s\n' "stale-start-token" > "$HOME/Applications/.NGMBridge-install.lock/started"
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/reuse.stdout" 2> "$TEMP/reuse.stderr" &
pid_a=$!
reuse_status=0
wait_pid "$pid_a" || reuse_status=$?
pid_a=""
if [[ "$reuse_status" -ne 0 ]]; then
    printf 'reused pid lock was not reclaimed\n' >&2
    cat "$TEMP/reuse.stdout" >&2 || true
    cat "$TEMP/reuse.stderr" >&2 || true
    exit 1
fi
[[ "$(cat "$TEMP/reuse.stdout")" == "Installed: $DEST" ]]
[[ -f "$DEST/Contents/MacOS/NGMBridge" ]]
[[ ! -e "$HOME/Applications/.NGMBridge-install.lock" ]]
printf 'PASS: a live pid with a different start time does not hold the lock\n'

rm -rf "$DEST"
rm -f "$FIXTURE_OPEN_LOG"
mkdir -p "$DEST"
printf 'preserve existing install\n' > "$DEST/preserve-marker"
cat > "$FIXTURE_ROOT/bin/mv" <<'STUB'
#!/bin/bash
set -euo pipefail
source_path=""
target_path=""
for arg in "$@"; do
    case "$arg" in
        -*)
            continue
            ;;
        *)
            if [[ -z "$source_path" ]]; then
                source_path="$arg"
            else
                target_path="$arg"
            fi
            ;;
    esac
done
# The previous app has been moved aside. Create the destination in the
# final rename, which is the window where plain mv nests and returns 0.
if [[ "$target_path" == "$DEST" && "$source_path" == *'.NGMBridge-install.'* && "$source_path" != *'/previous.app' ]]; then
    if [[ ! -e "$DEST" && ! -L "$DEST" ]]; then
        mkdir -p "$DEST"
        printf 'intruder\n' > "$DEST/intruder-marker"
    fi
fi
exec /bin/mv "$@"
STUB
chmod +x "$FIXTURE_ROOT/bin/mv"
status=0
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/race.stdout" 2> "$TEMP/race.stderr" || status=$?
[[ "$status" -ne 0 ]]
[[ ! -s "$TEMP/race.stdout" ]]
[[ "$(cat "$DEST/preserve-marker")" == "preserve existing install" ]]
[[ ! -e "$DEST/intruder-marker" ]]
[[ -z "$(find "$DEST" -mindepth 1 \( -name 'NGMBridge.app' -o -name '.NGMBridge-install.incoming.*' \) -print)" ]]
[[ ! -e "$FIXTURE_OPEN_LOG" ]]
displaced_line="$(grep -F 'Unexpected destination retained at: ' "$TEMP/race.stderr")"
[[ "$(printf '%s\n' "$displaced_line" | wc -l | tr -d '[:space:]')" == "1" ]]
displaced="${displaced_line#Unexpected destination retained at: }"
[[ -n "$displaced" && -f "$displaced/intruder-marker" ]]
[[ "$(cat "$displaced/intruder-marker")" == "intruder" ]]
[[ -z "$(find "$displaced" -mindepth 1 -name '.NGMBridge-install.incoming.*' -print)" ]]
[[ -z "$(find "$HOME/Applications" -name '.NGMBridge-install.*' -print)" ]]
printf 'PASS: destination created during the final rename restores the backup and fails\n'

# mv -n exits 1 and leaves the source when dest already contains NGMBridge.app.
# The installer must not move that existing app into staging.
rm -rf "$DEST"
rm -f "$FIXTURE_OPEN_LOG"
mkdir -p "$DEST"
printf 'preserve existing install\n' > "$DEST/preserve-marker"
cat > "$FIXTURE_ROOT/bin/mv" <<'STUB'
#!/bin/bash
set -euo pipefail
source_path=""
target_path=""
for arg in "$@"; do
    case "$arg" in
        -*)
            continue
            ;;
        *)
            if [[ -z "$source_path" ]]; then
                source_path="$arg"
            else
                target_path="$arg"
            fi
            ;;
    esac
done
if [[ "$target_path" == "$DEST" && "$source_path" == *'/NGMBridge.app' && "$source_path" != *'/previous.app' ]]; then
    mkdir -p "$DEST/NGMBridge.app"
    printf 'competitor\n' > "$DEST/NGMBridge.app/marker"
    exit 1
fi
exec /bin/mv "$@"
STUB
chmod +x "$FIXTURE_ROOT/bin/mv"
compete_status=0
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/compete.stdout" 2> "$TEMP/compete.stderr" || compete_status=$?
[[ "$compete_status" -ne 0 ]]
[[ ! -s "$TEMP/compete.stdout" ]]
[[ "$(cat "$DEST/preserve-marker")" == "preserve existing install" ]]
competitor="$(find "$HOME/Applications" -name marker -print)"
[[ -n "$competitor" ]]
[[ "$(cat "$competitor")" == "competitor" ]]
[[ ! -e "$FIXTURE_OPEN_LOG" ]]
printf 'PASS: refusing mv -n does not take an existing NGMBridge.app out of the destination\n'

rm -f "$FIXTURE_ROOT/bin/mv"
rm -rf "$DEST"
find "$HOME/Applications" -maxdepth 1 -name '.NGMBridge-displaced.*' -exec rm -rf {} +
mkdir -p "$HOME/Applications/.NGMBridge-install.orphan/previous.app"
printf 'keep-backup\n' > "$HOME/Applications/.NGMBridge-install.orphan/previous.app/preserve-marker"
cat > "$FIXTURE_ROOT/bin/mv" <<'STUB'
#!/bin/bash
set -euo pipefail
source_path=""
target_path=""
for arg in "$@"; do
    case "$arg" in
        -*)
            continue
            ;;
        *)
            if [[ -z "$source_path" ]]; then
                source_path="$arg"
            else
                target_path="$arg"
            fi
            ;;
    esac
done
if [[ "$source_path" == *'/previous.app' && "$target_path" == "$DEST" ]]; then
    mkdir -p "$DEST"
fi
exec /bin/mv "$@"
STUB
chmod +x "$FIXTURE_ROOT/bin/mv"
keep_status=0
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/keep.stdout" 2> "$TEMP/keep.stderr" || keep_status=$?
[[ "$keep_status" -eq 0 ]]
[[ "$(cat "$TEMP/keep.stdout")" == "Installed: $DEST" ]]
[[ -f "$HOME/Applications/.NGMBridge-install.orphan/previous.app/preserve-marker" ]]
[[ "$(cat "$HOME/Applications/.NGMBridge-install.orphan/previous.app/preserve-marker")" == "keep-backup" ]]
[[ ! -e "$DEST/previous.app" ]]
[[ -f "$DEST/Contents/MacOS/NGMBridge" ]]
printf 'PASS: a destination that appears before restore does not swallow the backup\n'

rm -f "$FIXTURE_ROOT/bin/mv"
rm -rf "$DEST" "$HOME/Applications/.NGMBridge-install.orphan"
find "$HOME/Applications" -maxdepth 1 -name '.NGMBridge-displaced.*' -exec rm -rf {} +
mkdir -p "$HOME/Applications/.NGMBridge-install.orphan/previous.app"
printf 'orphan backup\n' > "$HOME/Applications/.NGMBridge-install.orphan/previous.app/preserve-marker"
rm -f "$FIXTURE_OPEN_LOG"
export FIXTURE_BUILD_STATUS=42
orphan_status=0
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/orphan.stdout" 2> "$TEMP/orphan.stderr" || orphan_status=$?
unset FIXTURE_BUILD_STATUS
[[ "$orphan_status" -eq 42 ]]
[[ "$(cat "$DEST/preserve-marker")" == "orphan backup" ]]
[[ ! -e "$HOME/Applications/.NGMBridge-install.orphan" ]]
[[ ! -e "$FIXTURE_OPEN_LOG" ]]
[[ -z "$(find "$HOME/Applications" -name '.NGMBridge-install.*' -print)" ]]
printf 'PASS: a failed install restores a previous app left in a temporary directory\n'

cat > "$FIXTURE_ROOT/bin/mv" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ "$1" == "$DEST" && "$2" == *'/previous.app' ]]; then
    /bin/mv "$@"
    kill -TERM "$PPID"
    exit 0
fi
exec /bin/mv "$@"
STUB
chmod +x "$FIXTURE_ROOT/bin/mv"
rm -f "$FIXTURE_OPEN_LOG"
signal_status=0
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/signal-mv.stdout" 2> "$TEMP/signal-mv.stderr" || signal_status=$?
[[ "$signal_status" -ne 0 ]]
[[ "$(cat "$DEST/preserve-marker")" == "orphan backup" ]]
[[ ! -s "$TEMP/signal-mv.stdout" ]]
[[ ! -e "$FIXTURE_OPEN_LOG" ]]
[[ -z "$(find "$HOME/Applications" -name '.NGMBridge-install.*' -print)" ]]
printf 'PASS: SIGTERM after the previous app is moved aside restores it\n'

rm -f "$FIXTURE_ROOT/bin/mv"
export CP_ENTERED="$TEMP/cp.entered"
export CP_RELEASE="$TEMP/cp.release"
rm -f "$CP_ENTERED" "$CP_RELEASE" "$FIXTURE_OPEN_LOG"
cat > "$FIXTURE_ROOT/bin/cp" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "-R" && "${2:-}" == "$FIXTURE_ROOT/.build/NGMBridge.app" ]]; then
    printf '%s\n' "$$" >> "$CP_ENTERED"
    while [[ ! -f "$CP_RELEASE" ]]; do
        sleep 0.05
    done
fi
exec /bin/cp "$@"
STUB
chmod +x "$FIXTURE_ROOT/bin/cp"
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/signal-cp.stdout" 2> "$TEMP/signal-cp.stderr" &
pid_a=$!
reached=0
ticks=0
while [[ "$ticks" -lt 100 ]]; do
    if [[ -s "$CP_ENTERED" ]]; then
        reached=1
        break
    fi
    if ! kill -0 "$pid_a" 2>/dev/null; then
        break
    fi
    sleep 0.05
    ticks=$((ticks + 1))
done
if [[ "$reached" != 1 ]]; then
    printf 'installer did not reach the staged copy before SIGTERM\n' >&2
    cat "$TEMP/signal-cp.stdout" >&2 || true
    cat "$TEMP/signal-cp.stderr" >&2 || true
    exit 1
fi
kill -TERM "$pid_a" 2>/dev/null || true
if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -P "$pid_a" 2>/dev/null || true
fi
cp_status=0
wait_pid "$pid_a" || cp_status=$?
pid_a=""
[[ "$cp_status" -ne 0 ]]
[[ "$(cat "$DEST/preserve-marker")" == "orphan backup" ]]
[[ ! -s "$TEMP/signal-cp.stdout" ]]
[[ ! -e "$FIXTURE_OPEN_LOG" ]]
[[ -z "$(find "$HOME/Applications" -name '.NGMBridge-install.*' -print)" ]]
printf 'PASS: SIGTERM during the staged copy releases the lock and keeps the installed app\n'

rm -f "$CP_ENTERED" "$CP_RELEASE"
unset NGMBRIDGE_INSTALL_LOCK_WAIT_LOG || true
export CP_ENTERED="$TEMP/cp.entered"
export CP_RELEASE="$TEMP/cp.release"
export NGMBRIDGE_INSTALL_LOCK_WAIT_LOG="$TEMP/lock-wait"
cat > "$FIXTURE_ROOT/bin/cp" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "-R" && "${2:-}" == "$FIXTURE_ROOT/.build/NGMBridge.app" ]]; then
    printf '%s\n' "$$" >> "$CP_ENTERED"
    while [[ ! -f "$CP_RELEASE" ]]; do
        sleep 0.05
    done
fi
exec /bin/cp "$@"
STUB
chmod +x "$FIXTURE_ROOT/bin/cp"
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/a.stdout" 2> "$TEMP/a.stderr" &
pid_a=$!
reached=0
ticks=0
while [[ "$ticks" -lt 100 ]]; do
    if [[ -s "$CP_ENTERED" ]]; then
        reached=1
        break
    fi
    if ! kill -0 "$pid_a" 2>/dev/null; then
        break
    fi
    sleep 0.05
    ticks=$((ticks + 1))
done
if [[ "$reached" != 1 ]]; then
    printf 'first installer did not reach the staged copy\n' >&2
    cat "$TEMP/a.stdout" >&2 || true
    cat "$TEMP/a.stderr" >&2 || true
    exit 1
fi
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/b.stdout" 2> "$TEMP/b.stderr" &
pid_b=$!
waited=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
    21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
    41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 \
    61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 \
    81 82 83 84 85 86 87 88 89 90 91 92 93 94 95 96 97 98 99 100; do
    if [[ -f "$NGMBRIDGE_INSTALL_LOCK_WAIT_LOG" ]] && grep -qx "$pid_b" "$NGMBRIDGE_INSTALL_LOCK_WAIT_LOG"; then
        waited=1
        break
    fi
    cp_lines="$(wc -l < "$CP_ENTERED" | tr -d '[:space:]')"
    if [[ "$cp_lines" != 1 ]]; then
        printf 'second installer copied without waiting for the lock\n' >&2
        exit 1
    fi
    if ! kill -0 "$pid_b" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
[[ "$waited" == 1 ]]
cp_lines="$(wc -l < "$CP_ENTERED" | tr -d '[:space:]')"
[[ "$cp_lines" == 1 ]]
printf 'go\n' > "$CP_RELEASE"
status_a=0
status_b=0
wait_pid "$pid_a" || status_a=$?
wait_pid "$pid_b" || status_b=$?
pid_a=""
pid_b=""
[[ "$status_a" -eq 0 && "$status_b" -eq 0 ]]
[[ "$(cat "$TEMP/a.stdout")" == "Installed: $DEST" ]]
[[ "$(cat "$TEMP/b.stdout")" == "Installed: $DEST" ]]
cmp "$FIXTURE_ROOT/.build/bin/NGMBridge" "$DEST/Contents/MacOS/NGMBridge"
[[ ! -e "$DEST/preserve-marker" ]]
[[ -z "$(find "$DEST" -mindepth 1 -name 'NGMBridge.app' -print)" ]]
cp_lines="$(wc -l < "$CP_ENTERED" | tr -d '[:space:]')"
[[ "$cp_lines" == 2 ]]
[[ -z "$(find "$HOME/Applications" -name '.NGMBridge-install.*' -print)" ]]
printf 'PASS: overlapping installers take the lock one at a time and do not nest\n'
