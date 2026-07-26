# Apple application rules

## Scope

- This directory owns the native iOS and macOS application frames.
- Keep shared state, view models, small SwiftUI views, and the `CoreClient`
  abstraction in `Packages/LorepiaKit`.
- Keep root navigation, document picking, windows, menus, keyboard shortcuts,
  and platform lifecycle in the corresponding app target.
- Do not access SQLite or parse content packages from Swift.

## Bindings

- Do not hand-edit generated UniFFI Swift files.
- Generated Swift sources belong under
  `Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated`.
- Generated XCFrameworks and other native binaries are build products and must
  not be committed.
- Keep the no-generated-bindings build usable through `FakeCoreClient`.
- A build with generated bindings must define
  `LOREPIA_UNIFFI_GENERATED` for the `LorepiaKit` target.

## Required checks

From `apps/apple`:

```bash
swift test --package-path Packages/LorepiaKit
xcodebuild -workspace Lorepia.xcworkspace -scheme LorepiaIOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -workspace Lorepia.xcworkspace -scheme LorepiaMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Report any check that cannot run separately from checks that passed.
