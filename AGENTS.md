# Repository rules

## Product architecture

- LorePia is a new local-first AI character chat application for Android, iOS,
  macOS, and Windows.
- Treat this repository as a greenfield project. Do not read or copy any older
  LorePia repository, checkout, implementation, or project memory. The sole
  approved native baseline is the frozen
  `Dokpamo/lorepia-native-reference` repository at
  `native-baseline-before-tauri-2026-08-02`.
- The production client is the Tauri 2 application under `apps/lorepia`.
- The Svelte/TypeScript frontend owns the shared product UI, navigation,
  presentation state, semantic accessibility markup, and cross-platform
  interaction behavior.
- Rust owns domain logic, content inspection, storage, chat orchestration,
  provider orchestration, validation, and security-sensitive state.
- Platform Tauri plugins own credential storage, file pickers, OS lifecycle,
  notifications, deep links, menus, and other native services.
- JavaScript must not access SQLite directly, receive raw API credentials, or
  receive unrestricted absolute paths.
- Provider networking and content-package parsing are performed by Rust.
- Implement new product features only in the Tauri mainline. Previous native
  applications are preserved in the frozen reference repository; copies that
  remain here during migration are reference and parity-test inputs only.
- Do not add a server, account system, cloud sync, billing, marketplace, remote
  web frontend, or deployment infrastructure without an explicit task.
- Do not add an arbitrary JavaScript Creator runtime. Creator work follows
  `docs/roadmaps/creator-platform-roadmap.md`.
- This repository has no open-source license. Do not add a `LICENSE` file or
  project-authored license headers. Preserve notices already carried by
  third-party generated tooling such as the Gradle wrapper.

## Migration boundary

- Preserve the existing database schema, asset layout, content identifiers,
  provider identifiers, and conversation and branch semantics first.
- Do not redesign Core API meaning merely for the Tauri frontend. The initial
  Tauri adapter maps the current Core contract exactly.
- A Core or storage redesign requires evidence and tests independent of the UI
  migration.
- Any data migration requires old-native fixtures, crash-safe cutover, and
  rollback tests.
- Use only project-owned synthetic databases and credentials for migration and
  upgrade tests. Never use an actual user database or credential.
- Keep the native applications in this repository until all release and source
  removal gates in `docs/migrations/tauri-mainline-migration.md` pass.

## Dependency boundary

- The frontend calls only high-level Tauri commands. Scoped platform-plugin
  operations remain behind that backend command boundary.
- The Tauri application layer depends on `shell-api`, not directly on
  `lorepia-core`.
- `shell-api` may depend on `lorepia-core` but contains no product domain logic.
- Platform plugins expose the minimum operation needed by the Tauri application
  adapter; they do not expose a generic filesystem, network, shell, or
  credential API.
- Neither frontend code nor platform plugins access SQLite or parse content
  packages independently.
- Keep Rust dependencies acyclic.
- Do not create a crate or folder only for a future feature.
- New third-party dependencies follow
  `docs/development/third-party-license-policy.md`.

## Generated code

- Keep the committed Tauri Android/iOS projects production-canonical. Build-only
  development identity/name overlays must match the exact normalization and
  drift policy in `docs/development/generated-code.md`.
- Do not hand-edit Tauri-generated application/project source. Run the
  documented deterministic Android aftercare helper, which may constrain only
  `file_paths.xml` and the three reviewed Gradle-wrapper metadata keys.
- Generated Kotlin and Swift binding sources are not hand-edited.
- Generated native binaries are never committed.
- Public binding API changes must regenerate sources and pass drift checks.

## Test data

- Commit only project-owned synthetic test data.
- Never commit user content, private conversations, credentials, or production
  databases.

## Required checks

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-features --locked
RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps --locked
```

Run the relevant frontend, Tauri, Android, Apple, or Windows checks for every
platform change.

## Definition of done

- Changed code builds on its supported host.
- Relevant tests pass.
- Public behavior is documented.
- Security-sensitive values remain behind the Rust or platform boundary.
- No empty future-facing folder, placeholder API, or fake success path is
  added.
- Reports distinguish executed checks from checks that could not run.
