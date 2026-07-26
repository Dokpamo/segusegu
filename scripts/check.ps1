$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-features --locked
$env:RUSTDOCFLAGS = "-D warnings"
cargo doc --workspace --no-deps --locked
cargo xtask check repository
