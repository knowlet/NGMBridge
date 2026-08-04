# Security Policy

## Sensitive data

Never include any of the following in an issue, pull request, log, screenshot, or test fixture:

- complete `ngm://` or `NexonPlug://` launch URLs;
- `passarg` contents;
- values beginning with `sess`;
- Beanfun cookies, OTPs, account identifiers, or browser storage;
- personal CrossOver bottle archives.

Replace credentials with obvious placeholders such as `sessREDACTED`.

## Reporting

Report a vulnerability privately to the repository owner. Do not open a public proof-of-concept containing a usable login token.

## Threat model summary

NGMBridge assumes the official login site is trusted to create a launch request. It validates the URL scheme, host, launch mode, field uniqueness, payload length, and game-code allowlist. It does not attempt to prove that a session token was issued to the current macOS user.
