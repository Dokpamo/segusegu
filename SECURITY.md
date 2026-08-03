# Security

## Reporting a vulnerability

Do not disclose a vulnerability, credential, private conversation, or malicious
test file in a public issue. Use GitHub's private vulnerability reporting flow
for this repository. If that flow is unavailable, contact the repository owner
privately before sharing technical details.

Include the affected revision, platform, impact, reproduction conditions, and a
minimal synthetic proof of concept. Do not include real user data.

## Security boundaries

The following are mandatory mainline and release boundaries. A capability file,
adapter stub, or frozen native test is not implementation evidence; unavailable
platform integrations, signing assets, or target hosts are reported as
blockers.

- Imported files remain untrusted until Rust inspection and user approval.
- The first-party platform integration copies selected files into an app-owned
  transport staging directory with a size limit. The Svelte frontend receives
  an opaque ticket and safe metadata, not the original or staged absolute path;
  `shell-api` resolves the ticket internally and Rust validates content and
  archives.
- The source hash is checked again at commit time.
- Rust accepts provider credentials only for the lifetime of a request and does
  not write them to SQLite or logs. The first-party platform plugin must
  preserve the existing Android Keystore, Apple Keychain, and Windows
  PasswordVault formats and return only availability or failure state to
  JavaScript.
- JavaScript never opens SQLite, receives stored credential material, performs
  provider networking, parses content packages, or receives unrestricted
  absolute paths.
- Remote model traffic is allowed only to user-selected HTTPS endpoints.
  Unencrypted HTTP is restricted to loopback development endpoints.
- Tauri commands and Channels expose bounded, typed, redacted projections.
  Credentials, authorization headers, private prompt bodies, raw provider
  bodies, and host paths are excluded from results, events, stable errors, and
  diagnostics.
- Release capabilities are explicit and least-privilege. Wildcard capability,
  unrestricted filesystem or shell access, remote frontend content, arbitrary
  external navigation, `eval`, and arbitrary downloaded JavaScript are
  prohibited. Development-only capability is not enabled in release builds.
- The frontend uses a strict Content Security Policy and an explicit outbound
  allowlist. Clipboard writes require a direct user action.
- Tauri Isolation is defense in depth for IPC; it is not a CPU, memory, or
  arbitrary-script sandbox. Creator `script-v1`, arbitrary remote HTML, and
  external-network-enabled creator packages are outside this migration.
- While the frozen Windows compatibility harness is retained, C ABI handles and
  buffers continue to have explicit ownership and release functions.

The frozen native applications remain only as behavioral-reference and
old-to-new upgrade-test harnesses. A passing native security test does not prove
the Tauri command, Channel, capability, CSP, or platform-plugin boundary.

## Supported versions

Only the latest default branch is currently supported. No production release
channel has been declared.
