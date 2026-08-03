#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$android_sdk" || ! -d "$android_sdk" ]]; then
  echo "Android SDK not found. Set ANDROID_HOME." >&2
  exit 1
fi

sdkmanager="$android_sdk/cmdline-tools/latest/bin/sdkmanager"
avdmanager="$android_sdk/cmdline-tools/latest/bin/avdmanager"
emulator="$android_sdk/emulator/emulator"
adb="$android_sdk/platform-tools/adb"
if [[ ! -x "$sdkmanager" || ! -x "$avdmanager" ]]; then
  echo "Android command-line tools are unavailable." >&2
  exit 1
fi

expected_api_level="36"
system_image="system-images;android-${expected_api_level};google_apis;x86_64"
"$sdkmanager" "platform-tools" "emulator" "$system_image"
if [[ ! -x "$emulator" || ! -x "$adb" ]]; then
  echo "Android emulator or platform tools are unavailable." >&2
  exit 1
fi
"$adb" start-server

export ANDROID_AVD_HOME
ANDROID_AVD_HOME="$(mktemp -d)"
echo "no" | "$avdmanager" create avd \
  --force \
  --name lorepia-ci \
  --package "$system_image" \
  --device pixel_6

log_path="$repo_root/android-emulator.log"
"$emulator" \
  -avd lorepia-ci \
  -no-window \
  -no-audio \
  -no-boot-anim \
  -no-metrics \
  -gpu swiftshader_indirect \
  -camera-back none \
  -camera-front none \
  -wipe-data \
  >"$log_path" 2>&1 &
emulator_pid=$!
trap 'kill "$emulator_pid" 2>/dev/null || true; wait "$emulator_pid" 2>/dev/null || true' EXIT

"$adb" wait-for-device
booted=""
for _attempt in $(seq 1 120); do
  if ! kill -0 "$emulator_pid" >/dev/null 2>&1; then
    cat "$log_path"
    exit 1
  fi
  booted="$(
    "$adb" shell getprop sys.boot_completed 2>/dev/null |
      tr -d '\r' ||
      true
  )"
  if [[ "$booted" == "1" ]]; then
    break
  fi
  sleep 2
done
if [[ "$booted" != "1" ]]; then
  echo "Android emulator did not finish booting." >&2
  exit 1
fi

actual_api_level="$("$adb" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
if [[ "$actual_api_level" != "$expected_api_level" ]]; then
  echo "Expected Android API $expected_api_level, got '$actual_api_level'." >&2
  exit 1
fi
echo "Android emulator API: $actual_api_level"

"$adb" shell settings put global window_animation_scale 0
"$adb" shell settings put global transition_animation_scale 0
"$adb" shell settings put global animator_duration_scale 0

cd "$repo_root/apps/android"
./gradlew connectedDebugAndroidTest
