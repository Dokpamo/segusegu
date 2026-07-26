#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

rustup component add clippy rustfmt
rustup target add \
  aarch64-linux-android \
  x86_64-linux-android \
  aarch64-apple-ios \
  aarch64-apple-ios-sim \
  x86_64-apple-ios

cargo fetch --locked
echo "LorePia Rust prerequisites are ready."
