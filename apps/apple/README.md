# LorePia Apple apps

## Overview

This directory contains two native SwiftUI applications in one Xcode
workspace:

- `LorepiaIOS` owns the iPhone and iPad app lifecycle, tab navigation, and
  other iOS integration.
- `LorepiaMac` owns the macOS app lifecycle, split-view navigation, menus,
  keyboard shortcuts, document picking, and drop handling.
- `Packages/LorepiaKit` owns shared native state, view models, small SwiftUI
  views, design tokens, Keychain integration, and the high-level `CoreClient`
  adapter.

Rust remains the only owner of package parsing, domain rules, SQLite
persistence, chat orchestration, and provider networking. When a platform
host exposes import, Swift copies a security-scoped document into a bounded
app-owned staging directory, then passes only that staged path to Rust.
Neither Apple app parses a content package or accesses SQLite.

The implemented native vertical slices are:

- iOS Home is intentionally reduced to one lower-screen `추가하기` action
  that opens an otherwise empty Create tab. Conversation-list rows do not
  render a separate chat/story mode badge.
- Matching edit, copy, regenerate, branch, delete, and selection actions in
  LorePia-owned surfaces use the LorePia-drawn glyph family. Platform symbols
  remain for native menus and where that family has no semantic counterpart,
  such as tabs, warnings, modes, and chevrons.
- Library reload and character selection from the persisted Rust store.
- Import staging with a 128 MiB maximum, inspection review, warning and block
  display, discard, commit, and Library refresh. A failed commit retains the
  Rust-owned inspection for retry or discard. A cancelled transport copy
  removes its partial staging file. The shared flow remains available to
  native hosts that expose import; the intentionally blank iOS Create tab
  currently provides no document-picker or import entry point.
- Conversation restore by character, persisted message reload, send,
  streaming delta polling, dropped-event recovery, generation and sequence
  filtering, and cancel. Chat and story mode plus branch selection live in the
  native room-settings sheet. User and assistant messages expose compact,
  always-visible copy, edit or regenerate, branch, and logical-delete actions.
  Empty-poll intervals and view resume reconcile against persisted messages.
- Provider profile create, update, delete, and selected-provider settings.
- API credentials stored only in Keychain. Credentials are not placed in the
  Rust database or application logs.

Import Review renders only the platform-neutral representative-image logical
identifier, media type, byte count, and unsupported optional CCv3 field names
returned by Rust. Swift does not receive a Rust staging path or raw preview
bytes.

The `CoreClient` adapter maps the complete UniFFI v4 surface: version metadata,
health, characters, import inspection, commit and discard, conversations,
messages, branch-safe edit/regeneration/removal, send, cancel, event batches,
provider profiles, settings, and database statistics. A production build
without the UniFFI binary shows an explicit unavailable-core state.
`FakeCoreClient` is selected explicitly by tests and previews; it is not a
production fallback.

This repository intentionally has no open-source license. Its source and
generated bindings do not grant permission to copy, redistribute, or
relicense the project. Generated native binaries are local build products and
must not be committed.

All commands below run from the repository root unless a section says
otherwise.

## Prerequisites

- An Apple Silicon Mac for the currently supported macOS build. The build
  produces only the `aarch64-apple-darwin` macOS Rust slice; it does not produce
  an Intel macOS library.
- Xcode with a Swift 6.1 or newer toolchain and SDKs capable of building the
  iOS 17.0 and macOS 14.0 deployment targets. The repository does not pin an
  Xcode release number; `Package.swift` pins Swift tools 6.1 and `project.yml`
  sets Swift language mode 6.0.
- Rust 1.96.0, as pinned by the repository `rust-toolchain.toml`.
- Xcode command-line tools, including `xcodebuild`, `xcrun`, and `lipo`.
- XcodeGen 2.44.0 or newer only when regenerating the committed Xcode project.
  CI pins XcodeGen 2.45.4.

The XCFramework contains an ARM64 iOS device slice, a universal ARM64/x86_64
iOS simulator slice, and an Apple Silicon macOS slice.

## Install Rust targets

Install every target used by the Apple build:

```bash
rustup target add \
  aarch64-apple-ios \
  aarch64-apple-ios-sim \
  x86_64-apple-ios \
  aarch64-apple-darwin
```

## Generate Swift bindings

Generate the Swift source, C header, and module map from the public UniFFI
contract:

```bash
./scripts/generate-bindings.sh swift
```

Generated files belong under
`apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated`. Do not
edit them by hand. A public binding change must regenerate them and pass the
generated-tree drift check.

## Build XCFramework

Build all Rust Apple slices and assemble the ignored XCFramework:

```bash
./scripts/build-apple.sh
```

This is the complete Apple build entry point. It regenerates Swift bindings,
builds the device, simulator, and macOS Rust libraries, creates
`target/apple/LorepiaCore.xcframework`, copies it to
`apps/apple/Packages/LorepiaKit/Artifacts/LorepiaCore.xcframework`, runs the
live `LorepiaKit` tests, and builds both application schemes.

Both XCFramework locations are ignored build output. Do not add either one to
source control.

## Run LorepiaKit tests

Run the shared package tests:

```bash
swift test --package-path apps/apple/Packages/LorepiaKit
```

When the ignored XCFramework exists, the package enables the generated UniFFI
adapter and the live binding contract tests. To exercise the frame without
generated bindings, force the explicit fake-core configuration:

```bash
LOREPIA_SKIP_GENERATED=1 \
  swift test --package-path apps/apple/Packages/LorepiaKit
```

After `./scripts/build-apple.sh`, run the complete live launch and native
navigation gate:

```bash
./scripts/test-apple-launch.sh
```

The gate boots an available iPhone simulator, launches the live iOS app, and
runs an XCUI test that taps Library, Chat, Settings, and Library while
verifying the rendered native screen content. It also builds and launches the
macOS app with `--lorepia-ci-smoke`. The macOS smoke waits with a bounded
timeout for each real SwiftUI detail to acknowledge the route sequence
Library, Chat, Settings, Import Review, and Library. Both apps validate the
live Rust core; the macOS smoke does not require Accessibility permission.

## Build iOS simulator target

Build the actual `LorepiaIOS` scheme from the repository root:

```bash
xcodebuild \
  -workspace apps/apple/Lorepia.xcworkspace \
  -scheme LorepiaIOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run `./scripts/build-apple.sh` first when the generated XCFramework is absent
or stale.

## Build macOS target

Build the actual `LorepiaMac` scheme from the repository root:

```bash
xcodebuild \
  -workspace apps/apple/Lorepia.xcworkspace \
  -scheme LorepiaMac \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The current XCFramework supplies only an Apple Silicon macOS library.

## Open the workspace

Open the committed workspace and choose `LorepiaIOS` or `LorepiaMac`:

```bash
open apps/apple/Lorepia.xcworkspace
```

The standard Debug Run action for `LorepiaIOS` enables
`--lorepia-dev-fixtures`. This loads the comprehensive, project-owned synthetic
development catalog in memory so character browsing, conversation history,
search, long and empty content, message states, provider selection, and chat
actions can be exercised without setup. The main catalog contains 12 synthetic
characters, 36 rooms, three provider profiles, and a prebuilt two-branch story.

Additional development scenarios can be selected by replacing the standard
argument in **Product > Scheme > Edit Scheme > Run > Arguments**:

- `--lorepia-dev-empty` loads the completely empty library, conversation, and
  provider state.
- `--lorepia-dev-provider-missing` loads the catalog without a configured
  provider.
- `--lorepia-dev-credential-missing` keeps the selected provider but removes
  its synthetic credential.
- `--lorepia-dev-provider-unselected` keeps the provider profiles but starts
  with no selected default.
- `--lorepia-dev-health-warning` loads the catalog with a simulated unhealthy
  core status.
- `--lorepia-dev-core-unavailable` exercises startup and read-error surfaces.
- `--lorepia-dev-load` loads 60 additional rooms and 600 additional messages
  for a total of 96 rooms.

The exact, deterministic UI-test showcases remain available separately:

- `--lorepia-chat-bubble-showcase` loads the fixed multi-room chat geometry
  showcase.
- `--lorepia-chat-history-showcase` loads the fixed long-history showcase.

All fixture scenarios use in-memory test clients, project-owned synthetic
content, and in-memory credentials. They do not read or write the production
database, Keychain, or user data. A Debug launch without a recognized fixture
argument also falls back to the comprehensive development catalog, so a direct
Simulator relaunch keeps the synthetic data even when Xcode scheme arguments
are omitted. Pass an optional scenario argument explicitly when launching
outside the scheme. To use the live Rust core in Debug, replace the fixture
argument with the explicit `--lorepia-live-core` opt-in.

`apps/apple/project.yml` is the source of truth for the committed Xcode project
structure. After changing targets or build settings, regenerate the project
from the repository root:

```bash
xcodegen generate \
  --spec apps/apple/project.yml \
  --project apps/apple
```

Do not edit generated project structure as a substitute for updating
`project.yml`.

## Directory layout

```text
Apps/iOS/                      iOS app entry point and OS integration
Apps/macOS/                    macOS app entry point and OS integration
Packages/LorepiaKit/           Shared state, views, and CoreClient adapter
  Sources/LorepiaKit/Bridge/   High-level and generated UniFFI boundary
  Artifacts/                   Ignored XCFramework build output
  Tests/LorepiaKitTests/       Shared, view-model, and live binding tests
Tests/iOSUITests/              Native iOS root-navigation UI test
Lorepia.xcworkspace/           Workspace to open in Xcode
Lorepia.xcodeproj/             Committed project generated from project.yml
project.yml                    XcodeGen source of truth
```

## Troubleshooting

### The production app says the core is unavailable

Run `./scripts/build-apple.sh` from the repository root. Production does not
fall back to `FakeCoreClient` when the generated binding or XCFramework is
missing.

### Swift package tests unexpectedly use generated bindings

An ignored XCFramework already exists. Remove that local build product or run
the test with `LOREPIA_SKIP_GENERATED=1`.

### The macOS link fails on an Intel Mac

The current build produces only `aarch64-apple-darwin`. Use an Apple Silicon
Mac; Intel macOS is not a supported app architecture in this repository.

### No iPhone simulator is available

Install an iOS simulator runtime in Xcode and create or enable an iPhone
simulator. `./scripts/test-apple-launch.sh` intentionally fails when it cannot
find one.

### The generated Xcode project drifts

Use the pinned-compatible XcodeGen version, regenerate from `project.yml`, and
review the resulting project diff. CI uses XcodeGen 2.45.4 and rejects project
drift.

### A public UniFFI API changed

Run `./scripts/generate-bindings.sh swift`, then
`./scripts/build-apple.sh`. Never patch the generated Swift, header, module
map, or native binary by hand.
