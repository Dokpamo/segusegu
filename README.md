# LorePia

LorePia is a local-first native AI character chat application for Android, iOS,
macOS, and Windows.

The repository contains a shared Rust core for safe character-package imports,
SQLite persistence, conversation state, prompt planning, and direct
user-configured model connections. Each platform keeps a native user interface
and owns its operating-system integration.

## Status

LorePia is in early development. The local import, Library, conversation,
provider, and streaming-chat vertical slices are implemented in the shared
core and connected to each native application. Platform builds and launch
smokes run independently on matching CI hosts.

| Platform | UI | Current status |
|---|---|---|
| Android | Kotlin + Jetpack Compose | Import, Library, chat, settings, UniFFI, and Keystore credentials |
| iOS | Swift + SwiftUI | Import, Library, chat, settings, UniFFI, and Keychain credentials |
| macOS | Swift + SwiftUI | Import, Library, chat, settings, UniFFI, and Keychain credentials |
| Windows | C# + WinUI 3 | Import, Library, chat, settings, C ABI, and PasswordVault credentials |

## Architecture

```text
Android ── UniFFI ─┐
iOS ───── UniFFI ──┤
macOS ─── UniFFI ──┼── lorepia-core ── content / storage / chat / providers
Windows ─ C ABI ───┘
```

Native applications own rendering, navigation, accessibility, file selection,
credential storage, and lifecycle. Rust owns content validation, local
persistence, conversations, prompt construction, generation orchestration, and
stable cross-platform behavior.

See [the architecture overview](docs/architecture/overview.md).

## Implemented core flows

- inspect CCv3 JSON and CHARX ZIP input behind explicit size and archive limits;
- reject traversal, absolute paths, symbolic links, normalized path collisions,
  and high compression ratios;
- snapshot picker input before review and verify every source and asset CAS
  write by SHA-256;
- persist immutable sources, CHARX assets, characters, conversations, messages,
  provider profiles, and settings;
- restore local state after process restart;
- add built-in providers with an API key, discover unknown HTTPS/loopback
  services from a site or redacted cURL, and review the resulting manifest
  before activation;
- merge the bundled and signed provider catalogs, synchronize model routes
  through a durable hash-bound review, and preserve temporarily missing
  routes and their presets;
- render provider-specific generation, reasoning, and prompt-cache controls
  from Core-owned capability and parameter contracts;
- run the optional setup assistant only through an explicitly selected local
  model route and a user-reviewed document-egress grant;
- stream versioned, ordered generation events and propagate cancellation;
- expose the same core through UniFFI and an opaque-handle C ABI.

## Repository layout

```text
apps/       Native Android, Apple, and Windows applications
crates/     Shared Rust domain and application logic
bindings/   Kotlin, Swift, and C ABI integration
tools/      Developer CLI and repository automation
testdata/   Project-owned synthetic security fixtures
docs/       Architecture, decisions, and development guides
scripts/    Short build and binding-generation entry points
```

## Development

Run all host-independent Rust checks:

```bash
./scripts/check.sh
```

Platform instructions:

- [Android](apps/android/README.md)
- [iOS and macOS](apps/apple/README.md)
- [Windows](apps/windows/README.md)

Cross-platform test layers, fixture rules, and repeatable performance scenarios
are documented in [the testing guide](docs/development/testing.md).

Current review and research records:

- [2026-07-28 repository code review](docs/reviews/2026-07-28-repository-review.md)
- [Hermes/OpenClaw agent-capability research](docs/architecture/agent-capabilities-research.md)
- [third-party license intake policy](docs/development/third-party-license-policy.md)

The current product has no account system, operated backend, cloud sync,
billing, marketplace, or web frontend. Model requests go only to an endpoint
explicitly selected by the user.

## Source terms

This repository does not contain an open-source license and grants no permission
to use, copy, modify, or distribute its contents.

Security reports must follow [SECURITY.md](SECURITY.md).
