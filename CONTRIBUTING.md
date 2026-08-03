# Contributing

This is a restricted-source project. Access to the repository does not grant a
license to reuse or distribute the code.

## Change workflow

1. Implement new product features in the Tauri mainline under `apps/lorepia`,
   not in the frozen Android, Apple, or Windows native applications.
2. Keep each branch and pull request focused on one behavior.
3. Preserve the dependency direction documented in
   `docs/architecture/dependency-rules.md`.
4. Keep domain behavior in Rust Core. `shell-api` may validate and translate the
   Tauri boundary but must preserve current Core semantics unless a separately
   justified and tested Core change is part of the work.
5. Add or update tests for every public behavior, including error and redaction
   cases at a changed IPC boundary.
6. Update frontend packages only through the one committed
   `apps/lorepia/package-lock.json`.
7. Regenerate bindings whenever a retained UniFFI surface changes.
8. Add SQLite schema changes as numbered, forward-only migrations with native
   baseline upgrade and rollback fixtures where applicable.
9. Update current documentation in the same change.

## Required checks

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-features --locked
RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps --locked
cargo xtask check repository
```

Run the host-independent Tauri frontend checks:

```bash
./scripts/check-tauri.sh
```

Run the relevant Tauri platform build, launch, integration, IME, accessibility,
and upgrade checks for the changed surface. Continue to run a frozen native
application check when that harness changes or supplies parity/upgrade evidence.
Never claim a platform build, launch, credential check, signing check, or
upgrade passed when it was not executed on a supported, authorized host.

## Generated code

Use `scripts/generate-bindings.sh kotlin` or
`scripts/generate-bindings.sh swift`. Do not edit generated Kotlin, Swift,
headers, native libraries, or Xcode frameworks manually.

Do not hand-edit `package-lock.json`; update it through the pinned npm toolchain.
Tauri configuration, capability declarations, command registration, and
`shell-api` DTOs are reviewed source rather than generated output.
Keep committed Tauri mobile projects production-canonical and follow the exact
regeneration, deterministic Android aftercare, development-overlay
normalization, and tracked-drift/nonignored-addition policy in
`docs/development/generated-code.md`.

## Tauri security boundary

- The Svelte frontend uses only allowlisted typed commands and ordered Channels.
- JavaScript does not open SQLite, parse packages, perform provider networking,
  receive stored credential material, or receive unrestricted absolute paths.
- Platform services return safe state or opaque identifiers. Credentials are
  supplied only to an authorized Rust operation for the minimum practical
  lifetime.
- Do not add a remote frontend, unrestricted filesystem or shell capability, or
  arbitrary downloaded JavaScript. Creator arbitrary-script execution is
  outside this migration.

## Test and diagnostic data

Commit only synthetic fixtures produced for this project. Logs attached to an
issue or pull request must remove credentials, prompt text, private file paths,
and provider response bodies.
