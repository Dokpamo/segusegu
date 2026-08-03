# LorePia

LorePia is a local-first AI character chat application for Android, iOS,
macOS, and Windows. The main product client is built with Tauri 2, Svelte 5,
and TypeScript over the existing shared Rust core.

## Status

Tauri 2 was adopted as the primary cross-platform client on 2026-08-02. This
repository is the active mainline, not an experimental or shadow client.
Migration is in progress, so the previous Compose, SwiftUI, and WinUI
applications remain temporarily as parity and upgrade-test inputs. They are
removed only after the documented release and source-removal gates pass.

The complete pre-migration native implementation is frozen separately:

| Item | Fixed value |
|---|---|
| Reference repository | `https://github.com/Dokpamo/lorepia-native-reference` |
| Baseline tag | `native-baseline-before-tauri-2026-08-02` |
| Baseline commit | `66e398fa6256f17b04c82569e6764a9e5332265c` |
| Migration branch | `codex/tauri-mainline-migration` |

See the [baseline record](docs/migrations/native-baseline.md), the
[accepted Tauri decision](docs/architecture/decisions/ADR-0006-adopt-tauri-primary-client.md),
and the [mainline migration plan](docs/migrations/tauri-mainline-migration.md).

## Architecture

```text
Svelte 5 / TypeScript product UI
              |
       scoped Tauri commands
              |
    apps/lorepia/src-tauri
       /              \
  shell-api      platform Tauri plugin
      |            /       |        \
lorepia-core    picker  credential  OS lifecycle
      |                   storage
content / storage / chat / providers
```

The bundled local frontend owns rendering, navigation, presentation state,
semantic accessibility markup, and shared interaction behavior. Rust owns
content validation, persistence, conversation and branch semantics, prompt
construction, generation orchestration, provider networking, and
security-sensitive state. Native Tauri plugins retain the OS-specific
credential, file-picker, lifecycle, notification, deep-link, and menu
boundaries.

The common frontend does not collapse OS security boundaries: JavaScript does
not access SQLite, receive raw credentials, receive unrestricted absolute
paths, parse content packages, or call provider endpoints directly.

See [the architecture overview](docs/architecture/overview.md) and
[platform bridges](docs/architecture/platform-bridges.md).

## Implemented Rust flows

The preserved Core contract already provides the domain behavior being mapped
into the Tauri client:

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
  through a durable hash-bound review, and preserve temporarily missing routes
  and their presets;
- render provider-specific generation, reasoning, and prompt-cache controls
  from Core-owned capability and parameter contracts;
- keep remote setup-assistant execution fail-closed until Rust can price and
  tokenize the exact prepared request; manual and deterministic discovery
  remain available;
- stream versioned, ordered generation events and propagate cancellation.

The initial Tauri adapter preserves the current Core API version 8,
`ChatEvent` version 4, collection-returning list methods, and `expected_head`
conversation semantics. It does not introduce cursor pagination or a synthetic
revision model as part of the UI migration.

## Repository layout

```text
apps/lorepia/   Tauri 2 and Svelte main product client
apps/android/   Previous Compose client retained until removal gates pass
apps/apple/     Previous iOS/macOS SwiftUI clients retained until gates pass
apps/windows/   Previous WinUI client retained until gates pass
crates/         Shared Rust domain, storage, chat, providers, and shell API
plugins/        Narrow platform-native Tauri integrations
bindings/       Existing UniFFI and C ABI contracts retained during migration
tools/          Developer CLI and repository automation
testdata/       Project-owned synthetic security and upgrade fixtures
docs/           Architecture, decisions, migration records, and guides
scripts/        Build, validation, and generated-code entry points
```

Directories appear as their real implementation lands; empty future-facing
folders and placeholder APIs are not committed.

## Development

Run all host-independent Rust checks:

```bash
./scripts/check.sh
```

The Tauri client has one frontend lockfile under `apps/lorepia` and uses a
bundled, non-SSR Vite frontend. Platform-specific build, launch, upgrade,
accessibility, and IME evidence must run on the matching host or hosted CI.
Checks that were not executed are reported as unverified, never as successful.

With Node `24.18.1`, run the host-independent Tauri checks:

```bash
./scripts/check-tauri.sh
```

Use the CI-equivalent development identities, SDK prerequisites, build
commands, and launch smokes in the [getting-started guide](docs/development/getting-started.md)
and the [Android](docs/development/android.md),
[Apple](docs/development/apple.md), or
[Windows](docs/development/windows.md) platform guide.

Migration references:

- [native baseline and rollback record](docs/migrations/native-baseline.md)
- [Tauri mainline migration and release gates](docs/migrations/tauri-mainline-migration.md)
- [Core-to-Tauri contract matrix](docs/migrations/core-tauri-contract-matrix.md)
- [Creator platform roadmap](docs/roadmaps/creator-platform-roadmap.md)
- [third-party license intake policy](docs/development/third-party-license-policy.md)

LorePia has no developer-operated backend, account system, cloud sync, billing,
or marketplace. Model requests go only through Rust to an endpoint explicitly
selected by the user. The Svelte frontend is packaged locally; LorePia does not
load a remote application frontend.

## Source terms

This repository does not contain an open-source license and grants no permission
to use, copy, modify, or distribute its contents.

Security reports must follow [SECURITY.md](SECURITY.md).
