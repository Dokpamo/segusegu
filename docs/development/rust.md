# Rust development

The workspace is pinned by `rust-toolchain.toml` and commits `Cargo.lock`.

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-features --locked
cargo doc --workspace --no-deps
```

Use `cargo run -p lorepia-cli -- inspect <file>` to exercise content inspection
without a native UI. Use `cargo xtask` for repository-owned automation.

Keep domain types free of platform or FFI types. Convert errors at binding
boundaries without exposing internal diagnostics or secrets.
