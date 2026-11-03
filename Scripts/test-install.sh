#!/bin/bash
set -euo pipefail

# Exercise the real scripts without Swift, signing, Launch Services, or the user's HOME.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
FIXTURE_ROOT="$TEMP/project with spaces"
mkdir -p "$FIXTURE_ROOT/Scripts" "$FIXTURE_ROOT/Resources" "$FIXTURE_ROOT/bin" \
    "$FIXTURE_ROOT/.build/bin" "$TEMP/home with spaces"
cp "$ROOT/Scripts/build-app.sh" "$ROOT/Scripts/install-user.sh" "$FIXTURE_ROOT/Scripts/"
printf 'fixture plist\n' > "$FIXTURE_ROOT/Resources/Info.plist"
printf 'fixture binary, never executed\n' > "$FIXTURE_ROOT/.build/bin/NGMBridge"

cat > "$FIXTURE_ROOT/bin/swift" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ "$*" == "build -c release --show-bin-path" ]]; then
    printf '%s\n' "$FIXTURE_ROOT/.build/bin"
elif [[ "$*" == "build -c release --product NGMBridge" ]]; then
    # SwiftPM's build command sends normal progress to stdout.
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

APP="$(bash "$FIXTURE_ROOT/Scripts/build-app.sh" 2> "$TEMP/build.stderr")"
[[ "$APP" == "$FIXTURE_ROOT/.build/NGMBridge.app" ]]
grep -q 'Building for production' "$TEMP/build.stderr"
grep -q 'fixture diagnostic' "$TEMP/build.stderr"
cmp "$FIXTURE_ROOT/.build/bin/NGMBridge" "$APP/Contents/MacOS/NGMBridge"
printf 'PASS: build stdout contains only the app path\n'

DEST="$HOME/Applications/NGMBridge.app"
mkdir -p "$DEST"
printf 'old install\n' > "$DEST/old-marker"
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/install.stdout" 2> "$TEMP/install.stderr"
cmp "$FIXTURE_ROOT/.build/bin/NGMBridge" "$DEST/Contents/MacOS/NGMBridge"
cmp "$FIXTURE_ROOT/Resources/Info.plist" "$DEST/Contents/Info.plist"
[[ ! -e "$DEST/old-marker" ]]
[[ "$(cat "$FIXTURE_OPEN_LOG")" == "$DEST" ]]
[[ "$(cat "$TEMP/install.stdout")" == "Installed: $DEST" ]]
grep -q 'Building for production' "$TEMP/install.stderr"
printf 'PASS: installer replaces the fixture and opens the correct path\n'

rm "$FIXTURE_OPEN_LOG"
printf 'preserve existing install\n' > "$DEST/preserve-marker"
export FIXTURE_BUILD_STATUS=42
status=0
bash "$FIXTURE_ROOT/Scripts/install-user.sh" > "$TEMP/failure.stdout" 2> "$TEMP/failure.stderr" || status=$?
[[ "$status" == 42 ]]
[[ -f "$DEST/preserve-marker" ]]
[[ ! -e "$FIXTURE_OPEN_LOG" ]]
printf 'PASS: build failure preserves the existing fixture without opening it\n'
