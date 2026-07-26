# Repository rules

## Product boundary

- LorePia is a new local-first native AI character chat application.
- Treat this repository as a greenfield project. Do not read or copy any older
  LorePia repository, checkout, implementation, or project memory.
- Do not add a server, account system, cloud sync, billing, marketplace, web
  frontend, plugin runtime, or deployment infrastructure without an explicit
  task.
- This repository has no open-source license. Do not add a `LICENSE` file or
  project-authored license headers. Preserve notices already carried by
  third-party generated tooling such as the Gradle wrapper.
- Rust owns domain logic, content inspection, storage, chat logic, and provider
  orchestration.
- Native applications own UI, navigation, accessibility, file pickers,
  credential storage, and platform lifecycle.

## Dependency boundary

- Platform apps call only the high-level bindings.
- Platform apps must not access SQLite or parse content packages independently.
- Bindings may depend on `lorepia-core` but must not contain product logic.
- Keep Rust dependencies acyclic.
- Do not create a crate or folder only for a future feature.

## Generated code

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

Run the relevant Android, Apple, or Windows checks for every platform change.

## Definition of done

- Changed code builds on its supported host.
- Relevant tests pass.
- Public behavior is documented.
- No empty future-facing folder or placeholder API is added.
- Reports distinguish executed checks from checks that could not run.
