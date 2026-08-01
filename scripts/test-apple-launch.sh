#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="$repo_root/apps/apple/Lorepia.xcworkspace"
export LOREPIA_SKIP_GENERATED=0
package_artifact="$repo_root/apps/apple/Packages/LorepiaKit/Artifacts/LorepiaCore.xcframework"
generated_dir="$repo_root/apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated"
generated_header="$generated_dir/LorepiaCoreFFI.h"
generated_modulemap="$generated_dir/LorepiaCoreFFI.modulemap"
ios_bundle_id="dev.lorepia.ios"
ios_console_timeout_seconds="${LOREPIA_IOS_CONSOLE_TIMEOUT_SECONDS:-60}"
mac_smoke_timeout_seconds="${LOREPIA_MAC_SMOKE_TIMEOUT_SECONDS:-60}"
simulator_transition_timeout_seconds="${LOREPIA_SIMULATOR_TRANSITION_TIMEOUT_SECONDS:-120}"

validate_positive_timeout() {
  local value="$1"
  local name="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive whole number of seconds." >&2
    return 1
  fi
}

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

  if [[ ! -s "$generated_header" || ! -s "$generated_modulemap" ]]; then
    echo "Generated UniFFI interface files are missing. Run ./scripts/build-apple.sh first." >&2
    return 1
  fi
  if [[ ! -d "$framework" || ! -s "$info_plist" ]]; then
    echo "Live Apple core is missing at $framework. Run ./scripts/build-apple.sh first." >&2
    return 1
  fi
  if ! plutil -lint "$info_plist" >/dev/null; then
    echo "Live Apple core has an invalid Info.plist at $info_plist." >&2
    return 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist" 2>/dev/null)" != "XFWK" ]]; then
    echo "Live Apple core is not an XCFramework at $framework." >&2
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
        echo "Live Apple core has unexpected slice metadata for $identifier." >&2
        return 1
        ;;
    esac
    index=$((index + 1))
  done
  if [[ "$library_count" -ne 3 ||
    "$found_ios_device" -ne 1 ||
    "$found_ios_simulator" -ne 1 ||
    "$found_macos" -ne 1 ]]; then
    echo "Live Apple core does not contain exactly the required Apple slices." >&2
    return 1
  fi

  for slice in ios-arm64 ios-arm64_x86_64-simulator macos-arm64; do
    library="$framework/$slice/liblorepia_uniffi.a"
    headers="$framework/$slice/Headers"
    if [[ ! -s "$library" ||
      ! -s "$headers/LorepiaCoreFFI.h" ||
      ! -s "$headers/module.modulemap" ]]; then
      echo "Live Apple core slice $slice is incomplete." >&2
      return 1
    fi
    if ! cmp -s "$generated_header" "$headers/LorepiaCoreFFI.h" ||
      ! cmp -s "$generated_modulemap" "$headers/module.modulemap"; then
      echo "Live Apple core slice $slice does not match the generated UniFFI interface." >&2
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
      echo "Live Apple core slice $slice has architectures '$actual_arches', expected '$expected_arches'." >&2
      return 1
    fi
  done
}

validate_positive_timeout "$ios_console_timeout_seconds" \
  "LOREPIA_IOS_CONSOLE_TIMEOUT_SECONDS"
validate_positive_timeout "$mac_smoke_timeout_seconds" \
  "LOREPIA_MAC_SMOKE_TIMEOUT_SECONDS"
validate_positive_timeout "$simulator_transition_timeout_seconds" \
  "LOREPIA_SIMULATOR_TRANSITION_TIMEOUT_SECONDS"
validate_xcframework "$package_artifact"

build_temp=""
ios_derived=""
mac_derived=""
package_cache=""
simulator_id=""
simulator_original_state=""
simulator_state_mutated=0
simulator_preferences_domain="com.apple.iphonesimulator"
simulator_keyboard_key="ConnectHardwareKeyboard"
simulator_keyboard_preference_present=0
simulator_keyboard_preference_value=""
simulator_keyboard_preference_touched=0
ios_console_pid=""
mac_pid=""
lifecycle_child_pid=""
child_wait_timed_out=0

monotonic_milliseconds() {
  /usr/bin/perl \
    -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000'
}

child_is_running() {
  local pid="$1"
  local process_state=""

  if ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  if ! process_state="$(
    ps -o stat= -p "$pid" 2>/dev/null |
      tr -d '[:space:]'
  )" || [[ -z "$process_state" ]]; then
    # A restricted process table must never turn into an unbounded wait.
    # Conservatively treat an unknown child as running until the deadline.
    return 0
  fi
  [[ "$process_state" != Z* ]]
}

terminate_child_process() {
  local pid="$1"
  local label="$2"
  local attempt=0

  if [[ -z "$pid" ]]; then
    return 0
  fi
  if child_is_running "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    for ((attempt = 0; attempt < 5; attempt++)); do
      if ! child_is_running "$pid"; then
        break
      fi
      sleep 0.05
    done
  fi
  if child_is_running "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" >/dev/null 2>&1 || true
  if child_is_running "$pid"; then
    echo "Failed to terminate $label process $pid." >&2
    return 1
  fi
}

wait_for_child_with_timeout() {
  local pid="$1"
  local timeout_seconds="$2"
  local deadline_milliseconds=0
  local now_milliseconds=0
  local child_status=0

  child_wait_timed_out=0
  if ! now_milliseconds="$(monotonic_milliseconds)"; then
    echo "Failed to read the monotonic clock while waiting for child $pid." >&2
    child_wait_timed_out=1
    return 125
  fi
  deadline_milliseconds=$((now_milliseconds + timeout_seconds * 1000))
  while true; do
    if ! child_is_running "$pid"; then
      if wait "$pid"; then
        return 0
      else
        child_status=$?
        return "$child_status"
      fi
    fi
    if ! now_milliseconds="$(monotonic_milliseconds)"; then
      echo "Failed to read the monotonic clock while waiting for child $pid." >&2
      child_wait_timed_out=1
      return 125
    fi
    if ((now_milliseconds >= deadline_milliseconds)); then
      break
    fi
    sleep 0.05
  done
  if ! child_is_running "$pid"; then
    if wait "$pid"; then
      return 0
    else
      child_status=$?
      return "$child_status"
    fi
  fi
  child_wait_timed_out=1
  return 124
}

run_command_with_timeout() {
  local label="$1"
  local timeout_seconds="$2"
  local command_status=0
  shift 2

  "$@" &
  lifecycle_child_pid=$!
  if wait_for_child_with_timeout \
    "$lifecycle_child_pid" \
    "$timeout_seconds"; then
    command_status=0
  else
    command_status=$?
  fi
  if [[ "$child_wait_timed_out" -eq 1 ]]; then
    echo "$label did not terminate within $timeout_seconds seconds." >&2
    terminate_child_process "$lifecycle_child_pid" "$label" || true
    lifecycle_child_pid=""
    return "$command_status"
  fi
  lifecycle_child_pid=""
  return "$command_status"
}

current_simulator_state() {
  local id="$1"
  xcrun simctl list devices |
    awk -v simulator_id="$id" '
      index($0, simulator_id) {
        if ($0 ~ /\(Booted\)/) {
          print "Booted"
        } else if ($0 ~ /\(Shutdown\)/) {
          print "Shutdown"
        } else {
          print "Other"
        }
        exit
      }
    '
}

wait_for_simulator_state() {
  local id="$1"
  local expected_state="$2"
  local timeout_seconds="$3"
  local deadline_milliseconds=0
  local now_milliseconds=0
  local observed_state=""

  if ! now_milliseconds="$(monotonic_milliseconds)"; then
    echo "Failed to read the monotonic clock while waiting for simulator $id." >&2
    return 1
  fi
  deadline_milliseconds=$((now_milliseconds + timeout_seconds * 1000))
  while true; do
    if ! observed_state="$(current_simulator_state "$id")"; then
      echo "Failed to inspect simulator $id while waiting for $expected_state." >&2
      return 1
    fi
    if [[ "$observed_state" == "$expected_state" ]]; then
      return 0
    fi
    if ! now_milliseconds="$(monotonic_milliseconds)"; then
      echo "Failed to read the monotonic clock while waiting for simulator $id." >&2
      return 1
    fi
    if ((now_milliseconds >= deadline_milliseconds)); then
      echo "Simulator $id did not reach $expected_state; last state was '$observed_state'." >&2
      return 1
    fi
    sleep 0.1
  done
}

# ConnectHardwareKeyboard is a Simulator-process-wide preference. This gate
# must run serially with other Simulator automation and restores the exact
# prior value (including key absence) from cleanup. It also restores the
# selected simulator to the Booted or Shutdown state observed before the gate.
cleanup() {
  local command_status=$?
  local cleanup_status=0
  local expected_keyboard_value=""
  local restored_keyboard_value=""
  local restored_simulator_state=""
  trap '' INT TERM
  set +e

  if ! terminate_child_process "$lifecycle_child_pid" "Apple lifecycle"; then
    cleanup_status=1
  fi
  lifecycle_child_pid=""
  if ! terminate_child_process "$mac_pid" "macOS smoke"; then
    cleanup_status=1
  fi
  mac_pid=""
  if ! terminate_child_process "$ios_console_pid" "iOS console"; then
    cleanup_status=1
  fi
  ios_console_pid=""

  if [[ -n "$simulator_id" ]]; then
    xcrun simctl terminate "$simulator_id" "$ios_bundle_id" \
      >/dev/null 2>&1 ||
      true
  fi
  if [[ "$simulator_state_mutated" -eq 1 && -n "$simulator_id" ]]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    if ! wait_for_simulator_state \
      "$simulator_id" \
      "Shutdown" \
      "$simulator_transition_timeout_seconds"; then
      cleanup_status=1
    fi
  fi
  if [[ "$simulator_keyboard_preference_touched" -eq 1 &&
    "$simulator_keyboard_preference_present" -eq 1 ]]; then
    case "$simulator_keyboard_preference_value" in
      1 | true | TRUE | yes | YES)
        expected_keyboard_value="1"
        if ! defaults write \
          "$simulator_preferences_domain" \
          "$simulator_keyboard_key" \
          -bool true; then
          cleanup_status=1
        fi
        ;;
      *)
        expected_keyboard_value="0"
        if ! defaults write \
          "$simulator_preferences_domain" \
          "$simulator_keyboard_key" \
          -bool false; then
          cleanup_status=1
        fi
        ;;
    esac
    restored_keyboard_value="$(
      defaults read \
        "$simulator_preferences_domain" \
        "$simulator_keyboard_key" \
        2>/dev/null
    )"
    if [[ "$restored_keyboard_value" != "$expected_keyboard_value" ]]; then
      echo "Failed to restore the Simulator hardware-keyboard preference." >&2
      cleanup_status=1
    fi
  elif [[ "$simulator_keyboard_preference_touched" -eq 1 ]]; then
    defaults delete \
      "$simulator_preferences_domain" \
      "$simulator_keyboard_key" \
      >/dev/null 2>&1 ||
      true
    if defaults read \
      "$simulator_preferences_domain" \
      "$simulator_keyboard_key" \
      >/dev/null 2>&1; then
      echo "Failed to remove the temporary Simulator hardware-keyboard preference." >&2
      cleanup_status=1
    fi
  fi
  if [[ "$simulator_state_mutated" -eq 1 &&
    "$simulator_original_state" == "Booted" ]]; then
    if ! xcrun simctl boot "$simulator_id" >/dev/null 2>&1; then
      restored_simulator_state="$(current_simulator_state "$simulator_id")"
      if [[ "$restored_simulator_state" != "Booted" ]]; then
        echo "Failed to restore simulator $simulator_id to Booted." >&2
        cleanup_status=1
      fi
    fi
    if ! run_command_with_timeout \
      "Simulator bootstatus restore" \
      "$simulator_transition_timeout_seconds" \
      xcrun simctl bootstatus "$simulator_id" -b \
      >/dev/null 2>&1; then
      echo "Simulator $simulator_id did not finish restoring to Booted." >&2
      cleanup_status=1
    fi
    if ! wait_for_simulator_state \
      "$simulator_id" \
      "Booted" \
      "$simulator_transition_timeout_seconds"; then
      cleanup_status=1
    fi
  fi
  if [[ "$simulator_state_mutated" -eq 1 ]]; then
    restored_simulator_state="$(current_simulator_state "$simulator_id")"
    if [[ "$restored_simulator_state" != "$simulator_original_state" ]]; then
      echo "Simulator $simulator_id restored as '$restored_simulator_state', expected '$simulator_original_state'." >&2
      cleanup_status=1
    fi
  fi
  if [[ -n "$build_temp" && -e "$build_temp" ]] &&
    ! rm -rf "$build_temp"; then
    echo "Failed to remove the Apple launch-gate temporary directory." >&2
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

if ! monotonic_milliseconds >/dev/null; then
  echo "Monotonic clock support is unavailable from /usr/bin/perl." >&2
  exit 1
fi
build_temp="$(mktemp -d "${TMPDIR:-/tmp}/lorepia-apple-launch.XXXXXX")"
ios_derived="$build_temp/ios"
mac_derived="$build_temp/macos"
package_cache="$build_temp/xcode-package-cache"
if simulator_keyboard_preference_value="$(
  defaults read \
    "$simulator_preferences_domain" \
    "$simulator_keyboard_key" \
    2>/dev/null
)"; then
  simulator_keyboard_preference_present=1
fi

device_line="$(
  xcrun simctl list devices available |
    awk '
      /iPhone/ && /\(Booted\)/ {
        print
        found = 1
        exit
      }
      /iPhone/ && /\(Shutdown\)/ && fallback == "" {
        fallback = $0
      }
      END {
        if (!found && fallback != "") {
          print fallback
        }
      }
    '
)"
simulator_id="$(
  printf '%s\n' "$device_line" |
    grep -Eo '[0-9A-Fa-f-]{36}' |
    head -n 1 ||
    true
)"
if [[ -z "$simulator_id" ]]; then
  echo "No available iPhone simulator was found." >&2
  exit 1
fi
case "$device_line" in
  *"(Booted)"*)
    simulator_original_state="Booted"
    ;;
  *"(Shutdown)"*)
    simulator_original_state="Shutdown"
    ;;
  *)
    echo "Simulator $simulator_id is neither Booted nor Shutdown." >&2
    exit 1
    ;;
esac

simulator_keyboard_preference_touched=1
defaults write \
  "$simulator_preferences_domain" \
  "$simulator_keyboard_key" \
  -bool false
simulator_state_mutated=1
xcrun simctl shutdown "$simulator_id" 2>/dev/null || true
if ! wait_for_simulator_state \
  "$simulator_id" \
  "Shutdown" \
  "$simulator_transition_timeout_seconds"; then
  exit 1
fi
xcrun simctl boot "$simulator_id"
if ! run_command_with_timeout \
  "Simulator bootstatus" \
  "$simulator_transition_timeout_seconds" \
  xcrun simctl bootstatus "$simulator_id" -b; then
  exit 1
fi
if ! wait_for_simulator_state \
  "$simulator_id" \
  "Booted" \
  "$simulator_transition_timeout_seconds"; then
  exit 1
fi

xcodebuild \
  -workspace "$workspace" \
  -scheme LorepiaIOS \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$ios_derived" \
  -packageCachePath "$package_cache" \
  CODE_SIGNING_ALLOWED=NO \
  build

ios_app="$ios_derived/Build/Products/Debug-iphonesimulator/LorePia.app"
if [[ ! -d "$ios_app" ]]; then
  echo "Built iOS application was not found at $ios_app." >&2
  exit 1
fi
xcrun simctl install "$simulator_id" "$ios_app"
xcrun simctl launch \
  --console \
  --terminate-running-process \
  "$simulator_id" \
  "$ios_bundle_id" \
  --lorepia-ci-smoke &
ios_console_pid=$!
if wait_for_child_with_timeout \
  "$ios_console_pid" \
  "$ios_console_timeout_seconds"; then
  ios_console_status=0
else
  ios_console_status=$?
fi
if [[ "$child_wait_timed_out" -eq 1 ]]; then
  echo "iOS console smoke launch did not terminate within $ios_console_timeout_seconds seconds." >&2
  exit 1
fi
ios_console_pid=""
if [[ "$ios_console_status" -ne 0 ]]; then
  echo "iOS console smoke launch exited with status $ios_console_status." >&2
  exit "$ios_console_status"
fi

xcodebuild \
  -workspace "$workspace" \
  -scheme LorepiaIOS \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$ios_derived" \
  -packageCachePath "$package_cache" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LorepiaIOSUITests \
  test

xcodebuild \
  -workspace "$workspace" \
  -scheme LorepiaMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$mac_derived" \
  -packageCachePath "$package_cache" \
  CODE_SIGNING_ALLOWED=NO \
  build

mac_executable="$mac_derived/Build/Products/Debug/LorePia.app/Contents/MacOS/LorePia"
if [[ ! -x "$mac_executable" ]]; then
  echo "Built macOS application was not found at $mac_executable." >&2
  exit 1
fi
SWIFT_BACKTRACE=enable=yes \
  "$mac_executable" --lorepia-ci-smoke \
  >"$repo_root/apple-macos-smoke.log" 2>&1 &
mac_pid=$!
if wait_for_child_with_timeout "$mac_pid" "$mac_smoke_timeout_seconds"; then
  mac_status=0
else
  mac_status=$?
fi
if [[ "$child_wait_timed_out" -eq 1 ]]; then
  echo "macOS smoke launch did not terminate within $mac_smoke_timeout_seconds seconds." >&2
  exit 1
fi
mac_pid=""
if [[ "$mac_status" -ne 0 ]]; then
  diagnostic_root="$HOME/Library/Logs/DiagnosticReports"
  if [[ -d "$diagnostic_root" ]]; then
    crash_report=""
    for _diagnostic_attempt in $(seq 1 15); do
      crash_report="$(
        find "$diagnostic_root" \
          -maxdepth 1 \
          -type f \
          \( -name 'LorePia*.ips' -o -name 'LorePia*.crash' \) \
          -mmin -5 \
          -print |
          sort |
          tail -n 1
      )"
      if [[ -n "$crash_report" ]]; then
        break
      fi
      sleep 1
    done
    if [[ -n "$crash_report" ]]; then
      {
        printf '\n--- macOS crash report: %s ---\n' "$crash_report"
        sed -n '1,320p' "$crash_report"
      } >>"$repo_root/apple-macos-smoke.log"
    fi
  fi
  {
    printf '\n--- macOS unified log ---\n'
    /usr/bin/log show \
      --last 3m \
      --style compact \
      --predicate 'process == "LorePia"' \
      2>&1 ||
      true
  } >>"$repo_root/apple-macos-smoke.log"
  exit "$mac_status"
fi
