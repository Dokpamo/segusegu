# Android development

The production Android client is built from the Tauri mainline under
`apps/lorepia`; new product features are implemented there. A complete Android
result requires a Tauri Android build, install, launch, and relevant emulator
flow on a matching host. A frontend-only build is insufficient.

## Tauri development target

The CI-equivalent Android development target requires:

- Node `24.18.1` from `.node-version`;
- Rust `1.96.0` with target `x86_64-linux-android`;
- Temurin JDK 21;
- Android platform 36, build-tools `36.0.0`, platform-tools, and the emulator;
- NDK `29.0.14206865`; and
- the `system-images;android-36;google_apis;x86_64` emulator image.

The build automatically reads `tauri.conf.json` and
`tauri.android.conf.json`, then applies the common and Android development
overlays in this exact order:

1. `src-tauri/tauri.dev.conf.json`;
2. `src-tauri/tauri.android.dev.conf.json`.

The Android overlay intentionally keeps base identifier `dev.lorepia.app` and
adds `debugApplicationIdSuffix = ".dev"`. The configured final development
application ID is therefore `dev.lorepia.app.dev`. With pinned Tauri CLI
`2.11.4`, the product-name overlay does not regenerate Android's static
`strings.xml`; the packaged development application label remains the
production label `LorePia`.

With an API-36 x86_64 emulator running and `ANDROID_HOME` pointing at the SDK,
the CI-equivalent build is:

```bash
cd apps/lorepia
npm ci --ignore-scripts
node ../../scripts/check-npm-licenses.mjs
export NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
export ANDROID_NDK_HOME="$NDK_HOME"
npm run tauri -- \
  android build \
  --debug \
  --target x86_64 \
  --apk \
  --ci \
  --config src-tauri/tauri.dev.conf.json \
  --config src-tauri/tauri.android.dev.conf.json
```

Install and launch the resulting development APK:

```bash
adb install -r \
  src-tauri/gen/android/app/build/outputs/apk/universal/debug/app-universal-debug.apk
adb shell am start -W -n \
  dev.lorepia.app.dev/dev.lorepia.app.MainActivity
adb shell pidof dev.lorepia.app.dev
```

As in CI, verify the packaged application ID, `allowBackup=false`, the full
backup/data-extraction exclusions, absence of broad storage/media permissions,
and a live process. The build mutates generated Android development overlays
before the workflow normalizes them for a complete drift check. Do not commit
those development mutations; follow
[the generated-code policy](generated-code.md).

Production `versionCode` is configured as `2`, monotonically above the frozen
native build `1`. The development APK must retain that base version code, but
this source setting is not proof that a signed production update succeeds.

The import picker uses `ACTION_OPEN_DOCUMENT` with a read-only URI grant and
copies into bounded app-private staging, so that product flow does not require
a `FileProvider`. Tauri's generated WebView camera file chooser does require
one for explicit capture. The checked-in provider is non-exported, grants URI
access, and exposes only the app-owned external-files `Pictures/` directory
through the named `tauri_capture_images` path. General `external-path`,
`cache-path`, `files-path`, and `root-path` grants are forbidden.

The hosted workflow currently uses source-text count/reference assertions for
the deny-only backup/data-extraction XML and byte-compares both files with the
frozen native baseline. It runs the deterministic generated-source check, then
asserts the built APK's `versionCode=2`, backup references, merged provider,
compiled `external-files-path` name/path, absence of general path roots, and
absence of broad storage/media permissions. These checks are configured, but a
clean hosted APK result has not yet been recorded.

The NDK above is the application-build value in the current hosted workflow.
The audited production-canonical project-regeneration environment is recorded
separately in the generated-code policy; do not silently substitute one claim
for the other.

A 2026-08-02 local Apple Silicon run with pinned Tauri CLI `2.11.4`, NDK
`27.3.13750724`, and the `aarch64` Rust target built a 264 MB universal debug
APK. Package inspection reported application ID `dev.lorepia.app.dev`,
`versionCode` `2`, minimum SDK `26`, target SDK `36`, and application label
`LorePia`. It retained `allowBackup=false`, both backup-rule references, one
non-exported restricted camera `FileProvider` for `Pictures/`, and no broad
media or storage permission. The generated `build.gradle.kts` gained exactly
one `applicationIdSuffix = ".dev"` while `strings.xml` remained
production-canonical with no `LorePia Dev` value.

The same APK installed successfully on a temporary API-36 arm64 emulator. Its
cold launch returned `Status: ok` in 1.143 seconds, and PID 4583 remained alive
through all ten one-second checks. UIAutomator reported 28 nodes including the
Library and Korean navigation/accessibility text, the 1080×2400 screenshot
showed the expected UI, and logcat contained no fatal Android runtime, Rust
panic, or `SIGABRT` marker.

That result is an unsigned development-simulator partial pass. It does not prove
the hosted NDK-29/x86_64 job, signed production update, old-native data or
credential continuity, real IME composition, TalkBack, or other accessibility
behavior.

## Frozen native harness

The Kotlin/Compose project under `apps/android` is frozen as a compatibility,
behavioral-reference, and old-to-new upgrade-test harness. See its README for
pinned SDK versions and commands. It may receive only parity, continuity,
security, or build-maintenance changes until the native removal gates pass.

Generate its retained bindings and native libraries before running a native
baseline check:

```bash
./scripts/build-android.sh
```

That command does not build or validate the Tauri Android client.
