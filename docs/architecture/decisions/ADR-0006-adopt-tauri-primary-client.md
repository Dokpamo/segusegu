# ADR-0006: Adopt Tauri 2 as Lorepia's Primary Cross-Platform Client

- Status: Accepted
- Date: 2026-08-02
- Decision branch: `codex/tauri-mainline-migration`
- Native baseline tag: `native-baseline-before-tauri-2026-08-02`
- Native baseline commit: `66e398fa6256f17b04c82569e6764a9e5332265c`
- Native baseline repository:
  `https://github.com/Dokpamo/lorepia-native-reference`

## Context

Lorepia has one Rust implementation of domain, import, storage, conversation,
chat, and provider behavior, but previously maintained separate Compose,
SwiftUI, and WinUI product interfaces. The resulting UI and state duplication
made shared product behavior expensive to evolve while still requiring a
stable, security-sensitive Rust boundary.

The complete native implementation has been frozen in a separate repository.
That repository preserves the behavioral contract and supplies upgrade,
comparison, and technical rollback fixtures while the active product proceeds
in this repository.

## Decision

Adopt Tauri 2 as Lorepia's primary Android, iOS, macOS, and Windows client.
This is an accepted mainline architecture, not a shadow client, experiment, or
conditional proof of viability.

The product application lives under `apps/lorepia` and uses Svelte 5,
TypeScript strict mode, and Vite as a packaged, non-SSR local frontend. The
framework name does not become the product directory name.

Ownership is divided as follows:

- Svelte/TypeScript owns shared product UI, navigation, presentation state,
  semantic accessibility markup, and cross-platform interaction behavior.
- Rust owns domain logic, content inspection, storage, conversation and branch
  semantics, chat and provider orchestration, validation, networking, and
  security-sensitive state.
- `shell-api` maps the existing Core contract to bounded UI projections,
  validates command input, redacts errors, and transports ordered events. It
  does not acquire product domain logic.
- The Tauri application adapter composes `shell-api` with the minimum scoped
  platform-plugin call and owns picker/vault coordination.
- Narrow platform Tauri plugins own credential storage, file pickers, OS
  lifecycle, notifications, deep links, menus, and other native services.

The initial adapter preserves existing identifiers, database and asset
semantics, collection-returning Core methods, `expected_head` concurrency
semantics, and the current versioned `ChatEvent` contract. A UI migration does
not justify cursor pagination, `expectedRevision`, or another Core/storage
redesign. Such changes require independent evidence and tests.

## Security boundary

A shared frontend does not imply a shared OS security boundary.

- JavaScript does not access SQLite, parse content packages, call provider
  endpoints, receive raw credentials, or receive unrestricted absolute paths.
- File import uses a native picker, an app-owned bounded transport copy, Rust
  inspection, explicit commit or discard, and cleanup.
- Credential operations retain each platform's existing Keystore, Keychain, or
  PasswordVault identity and compensation semantics.
- Native-equivalent in-process credential rollback is not represented as crash
  safety. Production cutover requires a separate durable Core/storage
  pre-install intent/outcome state, startup reconciliation, and
  crash/failure-injection evidence.
- Tauri commands and capabilities are explicit and least-privilege. Generic
  shell, filesystem, network, and external-navigation access remain disabled.
- High-rate generation deltas use an ordered Tauri Channel. Persisted Core state
  is the reconciliation authority after lag, disposal, process restart, or
  lifecycle transition.

## Adoption and release gates

Tauri adoption is already decided. Data, credential, accessibility, IME,
performance, platform build, and upgrade validation are production-release and
native-source-removal gates; they are not adoption gates.

A production release cannot cut over until the Tauri client demonstrates on
every supported platform:

- existing data-root, database, asset, provider, route, preset, conversation,
  branch, and identifier continuity;
- synthetic credential continuity without exposing a secret to JavaScript;
- crash-safe reconciliation of OS-vault installation with the matching Core
  connection mutation;
- Library, Import, Chat, message action, branch, Provider Settings, discovery,
  model-sync, and catalog parity;
- Korean, Japanese, and Chinese IME correctness and platform input behavior;
- semantic accessibility plus VoiceOver, TalkBack, Narrator, and macOS
  accessibility smokes;
- ordered stream, cancellation, disposal, lag reconciliation, background and
  foreground restoration, and process-restart behavior;
- platform build, install, launch, signing, and upgrade evidence; and
- the required Rust, frontend, Tauri, dependency, and platform CI checks.

The previous native source remains in this repository until the separate
source-removal gate passes. Its removal is a distinct commit after release
evidence exists. UniFFI and the C ABI remain until no runtime or contract test
depends on them and equivalent coverage exists at the Tauri boundary.

## Creator scope

This decision does not approve an arbitrary Creator script runtime,
downloaded JavaScript, remote HTML, creator networking, creator filesystem
access, creator native API access, or creator Tauri IPC access.

Creator work proceeds separately through the
[Creator platform roadmap](../../roadmaps/creator-platform-roadmap.md).
`declarative-v1` is the first intended format. `html-static-v1` requires a
separate security review, and `script-v1` requires an independent security and
store-policy RFC plus a new architecture decision.

Creator Runtime or Creator Studio is not a completion condition for the Tauri
mainline migration.

## Consequences

- Product UI and presentation state can evolve once across four platforms.
- OS-specific code remains necessary for security, lifecycle, accessibility,
  input, packaging, signing, and distribution.
- The Tauri command and capability surface becomes a security-sensitive public
  contract and must remain narrow, typed, versioned, and tested.
- Native and Tauri clients temporarily coexist in this repository, increasing
  CI and maintenance cost until release and removal gates pass.
- The frozen native repository is not a branch for new product development.

If a release criterion fails, the team fixes the identified issue or records a
different architecture in a new ADR. Failure does not silently change this
Accepted decision back to the superseded native-UI architecture.

Technical rollback must nevertheless remain possible: the frozen repository
must stay cloneable and buildable at the fixed tag, and upgrade fixtures must
prove that a rollback does not corrupt the Core database or assets.

## Related records

- [Native baseline](../../migrations/native-baseline.md)
- [Tauri mainline migration](../../migrations/tauri-mainline-migration.md)
- [Superseded ADR 0002](../../adr/0002-rust-core-native-ui.md)
