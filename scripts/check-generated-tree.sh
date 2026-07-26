#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scope="${1:?usage: check-generated-tree.sh kotlin|swift|testdata|apple-project}"

case "$scope" in
  kotlin)
    tree_root="apps/android/app/src/main/generated"
    expected_paths=(
      "apps/android/app/src/main/generated/dev/lorepia/core/lorepia_uniffi.kt"
    )
    ;;
  swift)
    tree_root="apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated"
    expected_paths=(
      "apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated/LorepiaCore.swift"
      "apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated/LorepiaCoreFFI.h"
      "apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated/LorepiaCoreFFI.modulemap"
    )
    ;;
  testdata)
    tree_root="testdata"
    expected_paths=(
      "testdata/README.md"
      "testdata/archives/absolute-path.zip"
      "testdata/archives/case-collision.zip"
      "testdata/archives/high-ratio.zip"
      "testdata/archives/mime-mismatch.zip"
      "testdata/archives/traversal.zip"
      "testdata/archives/unicode-collision.zip"
      "testdata/cards/minimal-v3.json"
      "testdata/packages/minimal.charx"
      "testdata/packages/with-avatar.charx"
    )
    ;;
  apple-project)
    tree_root="apps/apple/Lorepia.xcodeproj"
    expected_paths=(
      "apps/apple/Lorepia.xcodeproj/project.pbxproj"
      "apps/apple/Lorepia.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
      "apps/apple/Lorepia.xcodeproj/xcshareddata/xcschemes/LorepiaIOS.xcscheme"
      "apps/apple/Lorepia.xcodeproj/xcshareddata/xcschemes/LorepiaMac.xcscheme"
    )
    ;;
  *)
    echo "unknown generated tree: $scope" >&2
    exit 2
    ;;
esac

expected="$(
  printf '%s\n' "${expected_paths[@]}" |
    LC_ALL=C sort
)"
actual="$(
  git ls-files --cached --others --exclude-standard -- "$tree_root" |
    LC_ALL=C sort
)"

if [[ "$actual" != "$expected" ]]; then
  echo "Generated tree manifest differs for '$scope'." >&2
  diff -u \
    <(printf '%s\n' "$expected") \
    <(printf '%s\n' "$actual") >&2 || true
  exit 1
fi

status="$(git status --porcelain=v1 --untracked-files=all -- "$tree_root")"
if [[ -n "$status" ]]; then
  echo "Generated tree has tracked or untracked drift for '$scope':" >&2
  printf '%s\n' "$status" >&2
  exit 1
fi

echo "generated tree is exact and clean: $scope"
