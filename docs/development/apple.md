# Apple development

The production iOS and macOS clients are built from the Tauri mainline under
`apps/lorepia`; new product features are implemented there. Complete Apple
results require the corresponding Tauri build and launch smoke on a matching
Xcode host. A frontend-only build is insufficient.

## Shared Tauri prerequisites

The current hosted jobs use:

- a `macos-15` runner with Xcode and the required simulator runtime;
- Node `24.18.1` from `.node-version`;
- Rust `1.96.0`; and
- Rust target `aarch64-apple-ios-sim` for the iOS simulator job.

The repository does not pin the hosted image's Xcode patch version. Record
`xcodebuild -version`, the SDK, simulator runtime, and destination when
reporting a local or CI result.

## macOS development build and launch

Tauri automatically reads `tauri.conf.json` and
`tauri.macos.conf.json`, then CI applies these overlays in order:

1. `src-tauri/tauri.dev.conf.json`;
2. `src-tauri/tauri.macos.dev.conf.json`.

The configured development bundle identifier is `dev.lorepia.mac.dev` and the
product name is `LorePia Dev`.

From the repository root, the CI-equivalent unsigned, unbundled build and
process launch are:

```bash
cd apps/lorepia
npm ci --ignore-scripts
node ../../scripts/check-npm-licenses.mjs
npm run tauri -- \
  build \
  --debug \
  --no-bundle \
  --ci \
  --config src-tauri/tauri.dev.conf.json \
  --config src-tauri/tauri.macos.dev.conf.json
../../target/debug/lorepia
```

The hosted smoke requires that process to remain alive for ten seconds. It does
not create, sign, install, or launch a production `.app`, and it does not prove
the effective Keychain access group or upgrade continuity.

A 2026-08-03 local run with the pinned Node and Rust versions completed this
unsigned arm64 no-bundle build in 16.61 seconds, produced
`target/debug/lorepia`, and kept the process alive for more than 10 seconds
before manual termination. The launch used the normal development identity and
the user's existing Application Support `LorePia Development` root; it was not
an isolated-home run, and that root's contents were not inspected. The
production root was not intentionally selected, but this smoke records no
before/after production-root stat or continuity proof. This is
development-process evidence only, not a signed package, isolated-data test, or
credential-continuity result.

Production macOS `bundleVersion` is configured as `2`, monotonically above the
frozen native `CURRENT_PROJECT_VERSION` of `1`. The no-bundle development
smoke does not inspect or prove that packaged release value.

## iOS simulator development build and launch

Tauri automatically reads `tauri.conf.json` and `tauri.ios.conf.json`, then CI
applies these overlays in order:

1. `src-tauri/tauri.dev.conf.json`;
2. `src-tauri/tauri.ios.dev.conf.json`.

The configured development bundle identifier is `dev.lorepia.ios.dev` and the
product name is `LorePia Dev`. CI deliberately clears signing inputs and builds
an unsigned `aarch64-sim` application:

```bash
cd apps/lorepia
npm ci --ignore-scripts
node ../../scripts/check-npm-licenses.mjs
unset \
  APPLE_DEVELOPMENT_TEAM \
  IOS_CERTIFICATE \
  IOS_CERTIFICATE_PASSWORD \
  IOS_MOBILE_PROVISION
npm run tauri -- \
  ios build \
  --debug \
  --target aarch64-sim \
  --ci \
  --no-sign \
  --config src-tauri/tauri.dev.conf.json \
  --config src-tauri/tauri.ios.dev.conf.json
```

Install and launch it on a disposable available iPhone simulator:

```bash
export LOREPIA_SIMULATOR_ID="<simulator-device-id>"
xcrun simctl boot "$LOREPIA_SIMULATOR_ID" || true
xcrun simctl bootstatus "$LOREPIA_SIMULATOR_ID" -b
xcrun simctl install \
  "$LOREPIA_SIMULATOR_ID" \
  "src-tauri/gen/apple/build/arm64-sim/LorePia Dev.app"
xcrun simctl launch \
  --terminate-running-process \
  "$LOREPIA_SIMULATOR_ID" \
  dev.lorepia.ios.dev
```

The hosted smoke verifies the built `Info.plist` bundle ID and keeps the
launched process alive for ten seconds. With the pinned Tauri CLI, the mobile
build leaves generated `project.yml` production-canonical and changes exactly
two bundle identifiers and two product names in the generated Xcode project.
It preserves source `Info.plist` `CFBundleVersion` `2`, but may remove that
file's final newline. CI normalizes only those observed mutations and checks the
complete generated Apple and permission trees for drift and nonignored
additions. Do not commit the development mutations; follow
[the generated-code policy](generated-code.md).

Production iOS `bundleVersion` and generated `CFBundleVersion` are `2`,
monotonically above the frozen native `CURRENT_PROJECT_VERSION` of `1`. The
unsigned simulator build does not prove a signed update.

A 2026-08-02 local run with pinned Tauri CLI `2.11.4` built the unsigned
`aarch64-sim` `LorePia Dev.app` at 129 MB. Its built `Info.plist` reported
bundle ID `dev.lorepia.ios.dev` and `CFBundleVersion` `2`. XcodeBuildMCP
installed and launched it on an iPhone 17 Pro simulator running iOS 26.5; after
ten seconds the live Library UI was visible, and the app then stopped cleanly.
Restoring the development mutations returned all 173 generated-tree paths to
their exact pre-build hashes.

That simulator result and the macOS development-process result above do not
prove a signed production update, installed production-container behavior,
effective Keychain access-group continuity, or native-seeded data and
credential continuity. A development identity cannot prove those properties.

## Frozen native harness

The SwiftUI projects under `apps/apple` are frozen as compatibility,
behavioral-reference, and old-to-new upgrade-test harnesses. See their README
for prerequisites. They may receive only parity, continuity, security, or
build-maintenance changes until the native removal gates pass.

```bash
./scripts/build-apple.sh
```

This retained command does not build or validate the Tauri iOS or macOS client.
