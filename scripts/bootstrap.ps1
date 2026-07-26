$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

rustup component add clippy rustfmt
rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc
cargo fetch --locked
Write-Host "LorePia Rust prerequisites are ready."
