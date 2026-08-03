#!/usr/bin/env bash
set -euo pipefail

path_requires_scope() {
  local selected_scope="$1"
  local changed_path="$2"
  case "$selected_scope:$changed_path" in
    rust:.cargo/* | \
    rust:Cargo.toml | \
    rust:Cargo.lock | \
    rust:.node-version | \
    rust:rust-toolchain.toml | \
    rust:rustfmt.toml | \
    rust:deny.toml | \
    rust:apps/lorepia/* | \
    rust:crates/* | \
    rust:plugins/* | \
    rust:bindings/* | \
    rust:tools/* | \
    rust:testdata/* | \
    rust:scripts/check-npm-licenses.mjs | \
    rust:scripts/generate-bindings.* | \
    rust:scripts/ci-path-filter.sh | \
    rust:.github/workflows/rust.yml)
      return 0
      ;;
    tauri:.cargo/* | \
    tauri:.gitignore | \
    tauri:.node-version | \
    tauri:Cargo.toml | \
    tauri:Cargo.lock | \
    tauri:rust-toolchain.toml | \
    tauri:rustfmt.toml | \
    tauri:deny.toml | \
    tauri:apps/lorepia/* | \
    tauri:crates/* | \
    tauri:plugins/* | \
    tauri:tools/* | \
    tauri:testdata/* | \
    tauri:scripts/check-npm-licenses.mjs | \
    tauri:scripts/normalize-tauri-android-generated.mjs | \
    tauri:scripts/check-tauri-capabilities.mjs | \
    tauri:scripts/check-tauri.sh | \
    tauri:scripts/check.sh | \
    tauri:scripts/check.ps1 | \
    tauri:scripts/ci-path-filter.sh | \
    tauri:.github/workflows/tauri.yml)
      return 0
      ;;
    android:apps/android/* | \
    android:bindings/uniffi/* | \
    android:tools/xtask/* | \
    android:crates/* | \
    android:testdata/* | \
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
    apple:testdata/* | \
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
    windows:testdata/* | \
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

validate_scope() {
  case "$1" in
    rust | tauri | android | apple | windows)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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
  assert_match true rust "apps/lorepia/src-tauri/src/lib.rs"
  assert_match true rust "plugins/lorepia-platform/src/lib.rs"
  assert_match true rust "apps/lorepia/src/App.svelte"
  assert_match true rust "apps/lorepia/package-lock.json"
  assert_match true rust ".node-version"
  assert_match true rust "scripts/check-npm-licenses.mjs"
  assert_match true tauri "apps/lorepia/src/App.svelte"
  assert_match true tauri "apps/lorepia/src-tauri/src/lib.rs"
  assert_match true tauri "crates/core/src/app.rs"
  assert_match true tauri "plugins/lorepia-platform/src/lib.rs"
  assert_match true tauri ".gitignore"
  assert_match true tauri "scripts/check-tauri-capabilities.mjs"
  assert_match true tauri "scripts/normalize-tauri-android-generated.mjs"
  assert_match false tauri "apps/android/app/src/main/AndroidManifest.xml"
  assert_match true android ".cargo/config.toml"
  assert_match true apple ".cargo/config.toml"
  assert_match true windows ".cargo/config.toml"
  assert_match true android "bindings/uniffi/src/lib.rs"
  assert_match true android "testdata/valid/minimal-v3.json"
  assert_match true apple "apps/apple/project.yml"
  assert_match true apple "testdata/valid/minimal-v3.json"
  assert_match true windows "bindings/c-api/include/lorepia.h"
  assert_match true windows "testdata/valid/minimal-v3.json"
  assert_match false windows "bindings/uniffi/src/lib.rs"
  assert_match false android "docs/architecture/overview.md"
  assert_match false apple "apps/windows/Lorepia.sln"
  if validate_scope "unknown"; then
    echo "unknown CI scope unexpectedly passed validation" >&2
    exit 1
  fi
  echo "ci path filter self-test passed"
  exit 0
fi

scope="${1:?usage: ci-path-filter.sh <rust|tauri|android|apple|windows> <base-sha> <head-sha>}"
if ! validate_scope "$scope"; then
  echo "unknown CI scope: $scope" >&2
  exit 2
fi
base_sha="${2:-}"
head_sha="${3:-HEAD}"

if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ||
      -z "$base_sha" ||
      "$base_sha" =~ ^0+$ ]]; then
  echo "true"
  exit 0
fi

if ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null ||
  ! git cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
  echo "true"
  exit 0
fi

changed_paths_file="$(
  mktemp "${TMPDIR:-/tmp}/lorepia-ci-changed-paths.XXXXXX"
)"
cleanup_changed_paths() {
  rm -f "$changed_paths_file"
}
trap cleanup_changed_paths EXIT
if ! git diff \
  --name-only \
  --no-renames \
  -z \
  "$base_sha" \
  "$head_sha" \
  >"$changed_paths_file"; then
  echo "true"
  exit 0
fi

while IFS= read -r -d '' changed_path; do
  if path_requires_scope "$scope" "$changed_path"; then
    echo "true"
    exit 0
  fi
done <"$changed_paths_file"

echo "false"
