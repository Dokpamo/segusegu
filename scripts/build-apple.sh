#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

./scripts/generate-bindings.sh swift

export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build -p lorepia-uniffi --release --target aarch64-apple-ios
cargo build -p lorepia-uniffi --release --target aarch64-apple-ios-sim
cargo build -p lorepia-uniffi --release --target x86_64-apple-ios
cargo build -p lorepia-uniffi --release --target aarch64-apple-darwin

generated_dir="apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated"
artifact_dir="target/apple"
package_artifact="apps/apple/Packages/LorepiaKit/Artifacts/LorepiaCore.xcframework"
rm -rf "$artifact_dir/LorepiaCore.xcframework" "$package_artifact"
mkdir -p "$artifact_dir/ios-device/Headers" \
  "$artifact_dir/ios-simulator/Headers" \
  "$artifact_dir/macos/Headers"

header="$(find "$generated_dir" -maxdepth 1 -name '*.h' -print -quit)"
modulemap="$(find "$generated_dir" -maxdepth 1 -name '*.modulemap' -print -quit)"
if [[ -z "$header" || -z "$modulemap" ]]; then
  echo "UniFFI Swift header or modulemap was not generated." >&2
  exit 1
fi
for headers in "$artifact_dir"/*/Headers; do
  cp "$header" "$headers/"
  cp "$modulemap" "$headers/module.modulemap"
done

cp target/aarch64-apple-ios/release/liblorepia_uniffi.a \
  "$artifact_dir/ios-device/liblorepia_uniffi.a"
lipo -create \
  target/aarch64-apple-ios-sim/release/liblorepia_uniffi.a \
  target/x86_64-apple-ios/release/liblorepia_uniffi.a \
  -output "$artifact_dir/ios-simulator/liblorepia_uniffi.a"
cp target/aarch64-apple-darwin/release/liblorepia_uniffi.a \
  "$artifact_dir/macos/liblorepia_uniffi.a"

xcodebuild -create-xcframework \
  -library "$artifact_dir/ios-device/liblorepia_uniffi.a" \
  -headers "$artifact_dir/ios-device/Headers" \
  -library "$artifact_dir/ios-simulator/liblorepia_uniffi.a" \
  -headers "$artifact_dir/ios-simulator/Headers" \
  -library "$artifact_dir/macos/liblorepia_uniffi.a" \
  -headers "$artifact_dir/macos/Headers" \
  -output "$artifact_dir/LorepiaCore.xcframework"
mkdir -p "$(dirname "$package_artifact")"
cp -R "$artifact_dir/LorepiaCore.xcframework" "$package_artifact"

swift test --package-path apps/apple/Packages/LorepiaKit
xcodebuild \
  -workspace apps/apple/Lorepia.xcworkspace \
  -scheme LorepiaIOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
xcodebuild \
  -workspace apps/apple/Lorepia.xcworkspace \
  -scheme LorepiaMac \
  CODE_SIGNING_ALLOWED=NO \
  build
