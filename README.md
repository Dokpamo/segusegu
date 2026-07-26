# LorePia

LorePia is a local-first native AI character chat application for Android, iOS,
macOS, and Windows.

The repository contains a shared Rust core for safe character-package imports,
SQLite persistence, conversation state, prompt planning, and direct
user-configured model connections. Each platform keeps a native user interface
and owns its operating-system integration.

## Status

LorePia is in early development. The Rust vertical slices are implemented and
covered by automated tests; native application frames and their bindings are
validated independently on the matching CI hosts.

| Platform | UI | Current status |
|---|---|---|
| Android | Kotlin + Jetpack Compose | Application frame and UniFFI integration |
| iOS | Swift + SwiftUI | Application frame and shared Swift package |
| macOS | Swift + SwiftUI | Application frame and shared Swift package |
| Windows | C# + WinUI 3 | Application frame and C ABI/P/Invoke integration |

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
- verify SHA-256 again between review and commit;
- persist immutable sources, characters, conversations, messages, and settings;
- restore local state after process restart;
- connect directly to HTTPS or loopback OpenAI-compatible endpoints;
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

The current product has no account system, operated backend, cloud sync,
billing, marketplace, or web frontend. Model requests go only to an endpoint
explicitly selected by the user.

## Source terms

This repository does not contain an open-source license and grants no permission
to use, copy, modify, or distribute its contents.

Security reports must follow [SECURITY.md](SECURITY.md).
