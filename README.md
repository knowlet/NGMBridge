# NGMBridge

A minimal macOS URL-scheme bridge that receives short-lived `ngm://launch/...` requests from the official game login website and launches the target Windows game through a selected CrossOver bottle.

## Design goals

- Use the official web login flow; never collect or store a Beanfun password.
- Accept only `ngm://launch` URLs.
- Parse `game` and `passarg` without invoking a shell.
- Restrict launches to configured game codes (`2982` by default).
- Never print the raw URL or session-bearing `passarg` values.
- Keep the CrossOver backend replaceable.

## Current status

MVP scaffold:

- [x] Strict NGM launch URL parser
- [x] Duplicate-field and malformed-input rejection
- [x] Configurable CrossOver path, bottle, executable, and allowlist
- [x] `Process.arguments` launch without shell interpolation
- [x] macOS `ngm` URL scheme registration
- [x] Unit tests with redacted fixture data
- [ ] Verify the exact CrossOver command against a real Classic bottle
- [ ] Add a settings UI
- [ ] Add optional `NexonPlug://` compatibility
- [ ] Add signed/notarized release workflow

## Configuration

On first launch, NGMBridge creates:

```text
~/Library/Application Support/NGMBridge/config.json
```

Default configuration:

```json
{
  "allowedGameCodes" : [
    "2982"
  ],
  "bottle" : "MapleStoryClassic",
  "crossoverAppPath" : "/Applications/CrossOver.app",
  "executable" : "Maplestory_Classic.exe",
  "launchMode" : "cxApp",
  "terminateAfterLaunch" : true
}
```

Launch modes:

- `cxApp`: runs `wine --bottle <bottle> --cx-app <executable>`.
- `direct`: runs an absolute macOS path to an `.exe` inside the selected bottle environment.

CrossOver documents `wine --bottle <bottle> --cx-app <executable.exe>` as its command-line interface:

- https://support.codeweavers.com/en_US/how-do-i-run-an-application-using-the-command-line

## Build and install

Requirements: macOS 13+, Xcode Command Line Tools, CrossOver.

```bash
bash ./Scripts/install-user.sh
```

The app is installed to:

```text
~/Applications/NGMBridge.app
```

Opening the app once registers the `ngm` URL scheme with Launch Services. The browser may ask for confirmation before opening NGMBridge.

## Development

```bash
swift test
bash ./Scripts/build-app.sh
```

A safe parser test fixture is included. Do not commit real `sess...` values or complete launch URLs.

## Security notes

The `passarg` field can contain a short-lived session credential. Treat a complete NGM URL as a bearer credential while it remains valid. NGMBridge intentionally:

- does not persist incoming URLs;
- does not include argument values in application logs;
- suppresses Wine debug output for the launch process;
- rejects game codes not present in the allowlist;
- avoids `/bin/sh -c` and passes every argument directly to `Process`.

This is an unofficial compatibility project. Game updates, anti-cheat behavior, login changes, or terms of service may make it stop working.
