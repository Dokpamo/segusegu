# Security

## Reporting a vulnerability

Do not disclose a vulnerability, credential, private conversation, or malicious
test file in a public issue. Use GitHub's private vulnerability reporting flow
for this repository. If that flow is unavailable, contact the repository owner
privately before sharing technical details.

Include the affected revision, platform, impact, reproduction conditions, and a
minimal synthetic proof of concept. Do not include real user data.

## Security boundaries

- Imported files remain untrusted until Rust inspection and user approval.
- Native apps copy selected files into an app-owned staging directory with a
  size limit; Rust validates content and archives.
- The source hash is checked again at commit time.
- Rust accepts provider credentials only for the lifetime of a request and does
  not write them to SQLite or logs. Android stores encrypted credential records
  behind a non-exportable Keystore key, Apple uses Keychain, and Windows uses
  PasswordVault.
- Remote model traffic is allowed only to user-selected HTTPS endpoints.
  Unencrypted HTTP is restricted to loopback development endpoints.
- C ABI handles and buffers have explicit ownership and release functions.

## Supported versions

Only the latest default branch is currently supported. No production release
channel has been declared.
