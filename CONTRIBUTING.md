# Contributing

This is a restricted-source project. Access to the repository does not grant a
license to reuse or distribute the code.

## Change workflow

1. Keep each branch and pull request focused on one behavior.
2. Preserve the dependency direction documented in
   `docs/architecture/dependency-rules.md`.
3. Add or update tests for every public behavior.
4. Regenerate bindings whenever the UniFFI surface changes.
5. Add SQLite schema changes as numbered, forward-only migrations.
6. Update current documentation in the same change.

## Required checks

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-features --locked
RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps --locked
cargo xtask check repository
```

Run the relevant native application checks listed in its README. Never claim a
platform build passed when it was not executed on a supported host.

## Generated code

Use `scripts/generate-bindings.sh kotlin` or
`scripts/generate-bindings.sh swift`. Do not edit generated Kotlin, Swift,
headers, native libraries, or Xcode frameworks manually.

## Test and diagnostic data

Commit only synthetic fixtures produced for this project. Logs attached to an
issue or pull request must remove credentials, prompt text, private file paths,
and provider response bodies.
