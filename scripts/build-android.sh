#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [[ ! -d "$android_sdk" ]]; then
  echo "Android SDK not found. Set ANDROID_HOME." >&2
  exit 1
fi

ndk_root="${ANDROID_NDK_HOME:-}"
if [[ -z "$ndk_root" ]]; then
  ndk_root="$(find "$android_sdk/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n 1)"
fi
if [[ ! -d "$ndk_root" ]]; then
  echo "Android NDK not found. Install NDK 27.2.12479018 or set ANDROID_NDK_HOME." >&2
  exit 1
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host_tag="darwin-x86_64" ;;
  Darwin-x86_64) host_tag="darwin-x86_64" ;;
  Linux-x86_64) host_tag="linux-x86_64" ;;
  *) echo "Unsupported Android build host." >&2; exit 1 ;;
esac

toolchain="$ndk_root/toolchains/llvm/prebuilt/$host_tag/bin"
if [[ ! -d "$toolchain" ]]; then
  echo "NDK LLVM toolchain not found at $toolchain" >&2
  exit 1
fi

./scripts/generate-bindings.sh kotlin

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$toolchain/aarch64-linux-android26-clang"
export CC_aarch64_linux_android="$toolchain/aarch64-linux-android26-clang"
export AR_aarch64_linux_android="$toolchain/llvm-ar"
cargo build -p lorepia-uniffi --release --target aarch64-linux-android
mkdir -p apps/android/app/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/liblorepia_uniffi.so \
  apps/android/app/src/main/jniLibs/arm64-v8a/

export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$toolchain/x86_64-linux-android26-clang"
export CC_x86_64_linux_android="$toolchain/x86_64-linux-android26-clang"
export AR_x86_64_linux_android="$toolchain/llvm-ar"
cargo build -p lorepia-uniffi --release --target x86_64-linux-android
mkdir -p apps/android/app/src/main/jniLibs/x86_64
cp target/x86_64-linux-android/release/liblorepia_uniffi.so \
  apps/android/app/src/main/jniLibs/x86_64/

(
  cd apps/android
  ./gradlew test lint assembleDebug
)
