#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export LOREPIA_SKIP_GENERATED=0

build_temp=""
publish_stage_root=""
publish_backup_root=""
publish_destination=""
publish_backup_artifact=""
publish_previous_moved=0
publish_new_installed=0
publish_transaction_active=0

reset_publish_state() {
  publish_stage_root=""
  publish_backup_root=""
  publish_destination=""
  publish_backup_artifact=""
  publish_previous_moved=0
  publish_new_installed=0
  publish_transaction_active=0
}

rollback_publish() {
  local rollback_status=0

  if [[ "$publish_transaction_active" -ne 1 ]]; then
    return 0
  fi

  if [[ "$publish_new_installed" -eq 1 && -n "$publish_destination" ]]; then
    if ! rm -rf -- "$publish_destination"; then
      echo "Failed to remove the uncommitted XCFramework at $publish_destination." >&2
      rollback_status=1
    fi
  fi
  if [[ "$publish_previous_moved" -eq 1 ]]; then
    if [[ ! -e "$publish_backup_artifact" ]]; then
      echo "The previous XCFramework backup is missing at $publish_backup_artifact." >&2
      rollback_status=1
    elif [[ -e "$publish_destination" ]]; then
      echo "Cannot restore the previous XCFramework because $publish_destination still exists." >&2
      rollback_status=1
    elif ! mv "$publish_backup_artifact" "$publish_destination"; then
      echo "Failed to restore the previous XCFramework from $publish_backup_artifact." >&2
      rollback_status=1
    fi
  fi

  if [[ "$rollback_status" -eq 0 ]]; then
    publish_transaction_active=0
  else
    echo "XCFramework recovery data was retained at $publish_backup_root." >&2
  fi
  return "$rollback_status"
}

cleanup() {
  local command_status=$?
  local cleanup_status=0
  trap '' INT TERM
  set +e

  if [[ "$publish_transaction_active" -eq 1 ]]; then
    if ! rollback_publish; then
      cleanup_status=1
    fi
  fi
  if [[ -n "$publish_stage_root" && -e "$publish_stage_root" ]]; then
    if ! rm -rf -- "$publish_stage_root"; then
      cleanup_status=1
    fi
  fi
  if [[ -n "$publish_backup_root" && -e "$publish_backup_root" ]]; then
    if [[ -n "$publish_backup_artifact" && -e "$publish_backup_artifact" ]]; then
      echo "XCFramework recovery data remains at $publish_backup_root." >&2
      cleanup_status=1
    elif ! rm -rf -- "$publish_backup_root"; then
      cleanup_status=1
    fi
  fi
  if [[ -n "$build_temp" && -e "$build_temp" ]] &&
    ! rm -rf -- "$build_temp"; then
    cleanup_status=1
  fi

  trap - EXIT
  if [[ "$command_status" -ne 0 ]]; then
    exit "$command_status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

build_temp="$(mktemp -d "${TMPDIR:-/tmp}/lorepia-apple-build.XXXXXX")"

./scripts/generate-bindings.sh swift

export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build -p lorepia-uniffi --release --target aarch64-apple-ios
cargo build -p lorepia-uniffi --release --target aarch64-apple-ios-sim
cargo build -p lorepia-uniffi --release --target x86_64-apple-ios
cargo build -p lorepia-uniffi --release --target aarch64-apple-darwin

generated_dir="apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated"
generated_header="$generated_dir/LorepiaCoreFFI.h"
generated_modulemap="$generated_dir/LorepiaCoreFFI.modulemap"
artifact_dir="$build_temp/apple"
candidate_artifact="$artifact_dir/LorepiaCore.xcframework"
target_artifact="target/apple/LorepiaCore.xcframework"
package_artifact="apps/apple/Packages/LorepiaKit/Artifacts/LorepiaCore.xcframework"
mkdir -p "$artifact_dir/ios-device/Headers" \
  "$artifact_dir/ios-simulator/Headers" \
  "$artifact_dir/macos/Headers"

if [[ ! -s "$generated_header" || ! -s "$generated_modulemap" ]]; then
  echo "UniFFI Swift header or modulemap was not generated." >&2
  exit 1
fi
for headers in "$artifact_dir"/*/Headers; do
  cp "$generated_header" "$headers/"
  cp "$generated_modulemap" "$headers/module.modulemap"
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
  -output "$candidate_artifact"

validate_xcframework() {
  local framework="$1"
  local info_plist="$framework/Info.plist"
  local identifier=""
  local platform=""
  local variant=""
  local library_path=""
  local headers_path=""
  local index=0
  local library_count=0
  local found_ios_device=0
  local found_ios_simulator=0
  local found_macos=0
  local slice=""
  local expected_arches=""
  local actual_arches=""
  local library=""
  local headers=""

  if [[ ! -d "$framework" || ! -s "$info_plist" ]]; then
    echo "XCFramework or Info.plist is missing at $framework." >&2
    return 1
  fi
  if ! plutil -lint "$info_plist" >/dev/null; then
    echo "XCFramework Info.plist is invalid at $info_plist." >&2
    return 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist" 2>/dev/null)" != "XFWK" ]]; then
    echo "XCFramework package type is not XFWK at $info_plist." >&2
    return 1
  fi

  while identifier="$(
    /usr/libexec/PlistBuddy \
      -c "Print :AvailableLibraries:$index:LibraryIdentifier" \
      "$info_plist" \
      2>/dev/null
  )"; do
    platform="$(
      /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:$index:SupportedPlatform" \
        "$info_plist" \
        2>/dev/null
    )" || return 1
    library_path="$(
      /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:$index:LibraryPath" \
        "$info_plist" \
        2>/dev/null
    )" || return 1
    headers_path="$(
      /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:$index:HeadersPath" \
        "$info_plist" \
        2>/dev/null
    )" || return 1
    variant="$(
      /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:$index:SupportedPlatformVariant" \
        "$info_plist" \
        2>/dev/null ||
        true
    )"
    library_count=$((library_count + 1))
    case "$identifier:$platform:$variant:$library_path:$headers_path" in
      ios-arm64:ios::liblorepia_uniffi.a:Headers)
        found_ios_device=$((found_ios_device + 1))
        ;;
      ios-arm64_x86_64-simulator:ios:simulator:liblorepia_uniffi.a:Headers)
        found_ios_simulator=$((found_ios_simulator + 1))
        ;;
      macos-arm64:macos::liblorepia_uniffi.a:Headers)
        found_macos=$((found_macos + 1))
        ;;
      *)
        echo "Unexpected XCFramework slice metadata for $identifier." >&2
        return 1
        ;;
    esac
    index=$((index + 1))
  done
  if [[ "$library_count" -ne 3 ||
    "$found_ios_device" -ne 1 ||
    "$found_ios_simulator" -ne 1 ||
    "$found_macos" -ne 1 ]]; then
    echo "XCFramework does not contain exactly the required Apple slices." >&2
    return 1
  fi

  for slice in ios-arm64 ios-arm64_x86_64-simulator macos-arm64; do
    library="$framework/$slice/liblorepia_uniffi.a"
    headers="$framework/$slice/Headers"
    if [[ ! -s "$library" ||
      ! -s "$headers/LorepiaCoreFFI.h" ||
      ! -s "$headers/module.modulemap" ]]; then
      echo "XCFramework slice $slice is incomplete." >&2
      return 1
    fi
    if ! cmp -s "$generated_header" "$headers/LorepiaCoreFFI.h" ||
      ! cmp -s "$generated_modulemap" "$headers/module.modulemap"; then
      echo "XCFramework slice $slice does not match the generated UniFFI interface." >&2
      return 1
    fi
    case "$slice" in
      ios-arm64 | macos-arm64)
        expected_arches="arm64"
        ;;
      ios-arm64_x86_64-simulator)
        expected_arches="arm64 x86_64"
        ;;
    esac
    actual_arches="$(
      lipo -archs "$library" |
        tr ' ' '\n' |
        sed '/^$/d' |
        sort |
        tr '\n' ' ' |
        sed 's/ $//'
    )"
    if [[ "$actual_arches" != "$expected_arches" ]]; then
      echo "XCFramework slice $slice has architectures '$actual_arches', expected '$expected_arches'." >&2
      return 1
    fi
  done
}

begin_publish() {
  local candidate="$1"
  local destination="$2"
  local destination_parent=""
  local staged_artifact=""

  if [[ "$publish_transaction_active" -eq 1 ]]; then
    echo "An XCFramework publish transaction is already active." >&2
    return 1
  fi
  validate_xcframework "$candidate"

  destination_parent="$(dirname "$destination")"
  mkdir -p "$destination_parent"
  publish_stage_root="$(
    mktemp -d "$destination_parent/.LorepiaCore.publish.XXXXXX"
  )"
  publish_backup_root="$(
    mktemp -d "$destination_parent/.LorepiaCore.backup.XXXXXX"
  )"
  staged_artifact="$publish_stage_root/LorepiaCore.xcframework"
  publish_backup_artifact="$publish_backup_root/LorepiaCore.xcframework"
  cp -R "$candidate" "$staged_artifact"
  validate_xcframework "$staged_artifact"

  publish_destination="$destination"
  publish_previous_moved=0
  publish_new_installed=0
  publish_transaction_active=1
  if [[ -e "$publish_destination" || -L "$publish_destination" ]]; then
    if ! mv "$publish_destination" "$publish_backup_artifact"; then
      publish_transaction_active=0
      echo "Failed to preserve the previous XCFramework at $publish_destination." >&2
      return 1
    fi
    publish_previous_moved=1
  fi
  if ! mv "$staged_artifact" "$publish_destination"; then
    echo "Failed to install the staged XCFramework at $publish_destination." >&2
    rollback_publish
    return 1
  fi
  publish_new_installed=1
  if ! validate_xcframework "$publish_destination"; then
    rollback_publish
    return 1
  fi
}

commit_publish() {
  if [[ "$publish_transaction_active" -ne 1 ]]; then
    echo "No XCFramework publish transaction is active." >&2
    return 1
  fi
  validate_xcframework "$publish_destination"
  publish_transaction_active=0
  if ! rm -rf -- "$publish_stage_root" "$publish_backup_root"; then
    echo "Failed to remove XCFramework publish staging data." >&2
    return 1
  fi
  reset_publish_state
}

validate_xcframework "$candidate_artifact"

# Keep the previous package artifact recoverable until all consumers have
# compiled and tested against this exact candidate.
begin_publish "$candidate_artifact" "$package_artifact"

swift test \
  --package-path apps/apple/Packages/LorepiaKit \
  --scratch-path "$build_temp/swiftpm" \
  --manifest-cache none \
  --disable-build-manifest-caching
xcodebuild \
  -workspace apps/apple/Lorepia.xcworkspace \
  -scheme LorepiaIOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$build_temp/ios-derived" \
  -packageCachePath "$build_temp/xcode-package-cache" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -workspace apps/apple/Lorepia.xcworkspace \
  -scheme LorepiaMac \
  -derivedDataPath "$build_temp/macos-derived" \
  -packageCachePath "$build_temp/xcode-package-cache" \
  CODE_SIGNING_ALLOWED=NO \
  build

commit_publish

# Preserve the documented target/apple output, but only after the package
# candidate has passed every Swift and Xcode gate.
begin_publish "$candidate_artifact" "$target_artifact"
commit_publish
