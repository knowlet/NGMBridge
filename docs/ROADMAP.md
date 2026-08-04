# Roadmap

## 0.1 — protocol bridge MVP

- Parse the observed `ngm://launch` command form.
- Register the macOS URL scheme.
- Forward redacted, validated arguments to CrossOver.
- Verify launch behavior with MapleStory Classic game code `2982`.

## 0.2 — operational hardening

- Settings window for CrossOver app path, bottle, and executable selection.
- Detect installed bottles and registered applications.
- Timestamp age policy with configurable clock-skew allowance.
- Single-flight and duplicate-URL suppression.
- Structured diagnostics that never contain `passarg`.

## 0.3 — compatibility

- Optional `NexonPlug://` parser.
- Cyder backend behind a common `GameRuntimeLauncher` protocol.
- Per-game configuration and separate allowlists.

## Release engineering

- GitHub Actions tests on macOS.
- Developer ID signing and notarization.
- Reproducible release archives and checksums.
