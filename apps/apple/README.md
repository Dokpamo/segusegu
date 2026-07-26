# LorePia Apple apps

This directory contains two native SwiftUI applications in one Xcode project
and workspace:

- `LorepiaIOS`: iPhone and iPad navigation and document picking.
- `LorepiaMac`: macOS split-view navigation, menus, keyboard shortcuts, file
  picking, and drop handling.
- `Packages/LorepiaKit`: shared `CoreClient`, state, view models, design tokens,
  and Library, Chat, Import Review, and Settings UI.

The project is intentionally buildable before generated UniFFI sources exist.
That configuration uses a clearly labelled `FakeCoreClient` with synthetic
health data. It does not read user content or duplicate Rust domain logic.

## Open and build

Open `Lorepia.xcworkspace`, then choose either the `LorepiaIOS` or
`LorepiaMac` scheme.

```bash
swift test --package-path Packages/LorepiaKit

xcodebuild \
  -workspace Lorepia.xcworkspace \
  -scheme LorepiaIOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -workspace Lorepia.xcworkspace \
  -scheme LorepiaMac \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`project.yml` is the source for the committed Xcode project structure. After
changing targets or build settings, regenerate it from this directory:

```bash
xcodegen generate --spec project.yml
```

## UniFFI integration

`UniFfiCoreClient` isolates all generated symbol references behind
`LOREPIA_UNIFFI_GENERATED`. The live adapter maps:

```text
coreVersion()                         -> CoreClient.version()
FfiCoreConfig(dataRoot:)             -> native application data root
LorepiaCore.open(config:)             -> one native core handle
LorepiaCore.healthCheck()             -> HealthStatus
```

`HealthStatus` preserves `coreVersion`, `databaseOpen`, `schemaVersion`,
`dataRootWritable`, `stagingWritable`, `recoveryPending`, and `activeJobs`.

From the repository root, build the Rust slices, create the XCFramework, run
the live binding tests, and build both applications with:

```bash
./scripts/build-apple.sh
```

The script generates Swift under
`Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated`, builds all required
iOS simulator/device and macOS Rust slices, assembles the ignored XCFramework,
and enables `LOREPIA_UNIFFI_GENERATED` through the package integration.

Generated Swift and native binaries must never be edited by hand. Native
binaries remain ignored build products.
