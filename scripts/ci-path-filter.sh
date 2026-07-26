#!/usr/bin/env bash
set -euo pipefail

path_requires_scope() {
  local selected_scope="$1"
  local changed_path="$2"
  case "$selected_scope:$changed_path" in
    rust:.cargo/* | \
    rust:Cargo.toml | \
    rust:Cargo.lock | \
    rust:rust-toolchain.toml | \
    rust:rustfmt.toml | \
    rust:deny.toml | \
    rust:crates/* | \
    rust:bindings/* | \
    rust:tools/* | \
    rust:testdata/* | \
    rust:scripts/generate-bindings.* | \
    rust:scripts/ci-path-filter.sh | \
    rust:.github/workflows/rust.yml)
      return 0
      ;;
    android:apps/android/* | \
    android:bindings/uniffi/* | \
    android:tools/xtask/* | \
    android:crates/* | \
    android:.cargo/* | \
    android:Cargo.toml | \
    android:Cargo.lock | \
    android:rust-toolchain.toml | \
    android:scripts/build-android.sh | \
    android:scripts/check-generated-tree.sh | \
    android:scripts/test-android-emulator.sh | \
    android:scripts/generate-bindings.sh | \
    android:scripts/ci-path-filter.sh | \
    android:.github/workflows/android.yml)
      return 0
      ;;
    apple:apps/apple/* | \
    apple:bindings/uniffi/* | \
    apple:tools/xtask/* | \
    apple:crates/* | \
    apple:.cargo/* | \
    apple:Cargo.toml | \
    apple:Cargo.lock | \
    apple:rust-toolchain.toml | \
    apple:scripts/build-apple.sh | \
    apple:scripts/check-generated-tree.sh | \
    apple:scripts/test-apple-launch.sh | \
    apple:scripts/generate-bindings.sh | \
    apple:scripts/ci-path-filter.sh | \
    apple:.github/workflows/apple.yml)
      return 0
      ;;
    windows:apps/windows/* | \
    windows:bindings/c-api/* | \
    windows:crates/* | \
    windows:.cargo/* | \
    windows:Cargo.toml | \
    windows:Cargo.lock | \
    windows:rust-toolchain.toml | \
    windows:scripts/build-windows.ps1 | \
    windows:scripts/generate-bindings.ps1 | \
    windows:scripts/ci-path-filter.sh | \
    windows:.github/workflows/windows.yml)
      return 0
      ;;
  esac
  return 1
}

assert_match() {
  local expected="$1"
  local selected_scope="$2"
  local changed_path="$3"
  local actual="false"
  if path_requires_scope "$selected_scope" "$changed_path"; then
    actual="true"
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "expected $selected_scope:$changed_path to be $expected, got $actual" >&2
    exit 1
  fi
}

if [[ "${1:-}" == "--self-test" ]]; then
  assert_match true android ".cargo/config.toml"
  assert_match true apple ".cargo/config.toml"
  assert_match true windows ".cargo/config.toml"
  assert_match true android "bindings/uniffi/src/lib.rs"
  assert_match true apple "apps/apple/project.yml"
  assert_match true windows "bindings/c-api/include/lorepia.h"
  assert_match false windows "bindings/uniffi/src/lib.rs"
  assert_match false android "docs/architecture/overview.md"
  assert_match false apple "apps/windows/Lorepia.sln"
  echo "ci path filter self-test passed"
  exit 0
fi

scope="${1:?usage: ci-path-filter.sh <scope> <base-sha> <head-sha>}"
base_sha="${2:-}"
head_sha="${3:-HEAD}"

if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ||
      -z "$base_sha" ||
      "$base_sha" =~ ^0+$ ]]; then
  echo "true"
  exit 0
fi

if ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
  echo "true"
  exit 0
fi

while IFS= read -r changed_path; do
  if path_requires_scope "$scope" "$changed_path"; then
    echo "true"
    exit 0
  fi
done < <(git diff --name-only "$base_sha" "$head_sha")

echo "false"
