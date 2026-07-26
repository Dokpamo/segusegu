#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="$repo_root/apps/apple/Lorepia.xcworkspace"
ios_derived="$repo_root/target/apple-launch/ios"
mac_derived="$repo_root/target/apple-launch/macos"

device_line="$(xcrun simctl list devices available | awk '/iPhone/ { print; exit }')"
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

xcrun simctl boot "$simulator_id" 2>/dev/null || true
trap 'xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true' EXIT
xcrun simctl bootstatus "$simulator_id" -b

xcodebuild \
  -workspace "$workspace" \
  -scheme LorepiaIOS \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$ios_derived" \
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
  dev.lorepia.ios \
  --lorepia-ci-smoke

xcodebuild \
  -workspace "$workspace" \
  -scheme LorepiaIOS \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$ios_derived" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LorepiaIOSUITests \
  test

xcodebuild \
  -workspace "$workspace" \
  -scheme LorepiaMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$mac_derived" \
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
for _attempt in $(seq 1 60); do
  if ! kill -0 "$mac_pid" 2>/dev/null; then
    set +e
    wait "$mac_pid"
    mac_status=$?
    set -e
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
    fi
    exit "$mac_status"
  fi
  sleep 1
done
kill "$mac_pid" 2>/dev/null || true
wait "$mac_pid" 2>/dev/null || true
echo "macOS smoke launch did not terminate within 60 seconds." >&2
exit 1
