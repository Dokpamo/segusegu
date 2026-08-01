# LorePia for Android

## Overview

LorePia is a local-first native AI character chat application. The Android app
is a single Kotlin and Jetpack Compose module. It owns Android UI, navigation,
document picking, bounded staging copies, accessibility, and lifecycle. Rust
owns content inspection, persistence, chat behavior, and provider orchestration.

The app opens one `LorepiaCore` per process and exposes the real core version,
structured health report, character library, import workflow, persisted
conversations, chat events, provider connections, model routes, generation
presets, capability evidence, and application settings.
Character files selected through Android's document picker are copied to an
app-only staging directory with a 50 MiB limit. Rust takes its own verified
inspection snapshot and returns structured warnings, blocked reasons, and an
estimated stored size. Only explicit user approval calls `commitImport`;
leaving before approval calls `discardImport` and removes Android's staged
copy.

Selecting a character opens its existing conversations or creates the first
one. The Chat screen restores persisted messages and resolves the selected
`ModelRoute` + `GenerationPreset` pair to its `ProviderConnection`. It reads
the credential by the immutable connection ID and submits through the typed
`sendMessageWithTarget` binding. The legacy provider-profile ID is retained
only for migration compatibility. Chat polls bounded event batches, rejects
stale generation or sequence events, streams text, and exposes cancellation.
Because the binding
event queue is process-wide, Chat also reconciles persisted messages after
dropped events, repeated empty batches, and route resume; a generation is
cleared when its pending persisted row is gone. Provider credentials are never
placed in Rust storage or ordinary preferences: Android encrypts them with a
non-exportable Android Keystore AES-GCM key and stores ciphertext in the app's
no-backup directory.

## AI provider setup

Settings presents the Rust-owned provider graph without parsing manifests or
opening SQLite on Android:

```text
ProviderTemplate
  -> ProviderConnection
    -> ModelRoute
      -> GenerationPreset
      -> CapabilityObservation
```

Known providers start with the minimum connection fields and require an
explicit exact-origin approval before Android stores a credential. Site-URL
and cURL setup modes are represented as review-gated discovery flows; raw
credentials and cURL input are never written to settings or saved instance
state. The generated discovery binding performs sanitization, network policy,
and review hashing.

When the selected chat target has an available model route, a matching preset,
and any required Keystore credential, Android offers that exact route as the
optional setup assistant. The route is frozen into the discovery input and is
shown again with the current preset before consent. Request, approval, and
execution are blocked if the selected model route changes or the current target
becomes unavailable.
Because a pre-consent Rust snapshot does not expose its frozen assistant route,
Android fails closed after process restart and asks the user to restart that
discovery instead of guessing a route.

Model synchronization is a durable Rust job. Android passes a Keystore secret
only to `startProviderModelSync`, polls non-secret job state, displays model and
capability diffs with provenance, and applies only the exact review hash the
user approved. Awaiting-review and interrupted jobs are restored after process
restart; Android never automatically repeats a credential-bearing request.

Credential and database mutations are serialized. A create writes Keystore
first and removes the new encrypted value when the core mutation fails or is
cancelled. An existing connection never accepts a replacement credential:
another account or endpoint must be added as a new connection. Delete removes
the credential first and restores it if the database refuses the deletion.
Connection IDs and the `dev.lorepia.provider-credentials.v1` Keystore alias
remain unchanged.

Generation controls come from `ParameterSpec`. Leaving a control on
“Provider default” omits that parameter from the preset rather than guessing a
value. The UI displays capability source, confidence, observation/expiry time,
staleness, and conflicts. Request previews are displayed only when the Rust
core supplies a redacted preview; Android never reconstructs a request or
inserts a credential into preview text.

For an enabled reasoning draft with no explicit effort, Android adopts a
non-empty exact default only when the Core renders it as ready, visible, and
allowed, then re-renders before preview or save. Selecting provider-default
reasoning atomically clears and omits effort, budget, and summary overrides.
Opaque reasoning continuity is available only when the Core permits it and the
route is credential-free; unknown or credential-bearing ownership fails closed.

## Prerequisites

- JDK 17
- Android Studio with Android SDK 36
- Android NDK installed for Rust cross-compilation
- Rust toolchain and Android Rust targets required by the repository scripts

Set `ANDROID_HOME` or create an uncommitted `local.properties` if Android Studio
cannot locate the SDK.

## Generate bindings

From the repository root:

```bash
./scripts/generate-bindings.sh kotlin
```

Generated Kotlin under `app/src/main/generated` is included as a read-only
source directory. Do not edit generated sources.

## Build Rust libraries

From the repository root:

```bash
./scripts/build-android.sh
```

The build must place each generated native library in the matching
`app/src/main/jniLibs/<abi>/` directory for local packaging. Native libraries
are build artifacts and must not be committed.

## Run tests

Local JVM tests, static analysis, and a debug build:

```bash
cd apps/android
./gradlew test lint assembleDebug
```

With an emulator or device whose ABI has a Rust library:

```bash
./gradlew connectedDebugAndroidTest
```

The instrumentation suite includes navigation, Import Review accessibility,
chat send/cancel UI, an Android Keystore encrypted-storage round trip, real
`MainActivity`/`Application` startup and Settings health, UniFFI lifecycle
checks (including rejection after `close()`), and a synthetic package
inspect/commit/library round trip.

Import Review shows Rust-provided representative-image metadata and unsupported
optional CCv3 field names. Android does not open the archive to derive either
value and never receives a Rust staging path or raw preview bytes.

## Build the app

```bash
cd apps/android
./gradlew assembleDebug
```

The APK is a local build artifact under `app/build/outputs/` and is not
committed.

## Open in Android Studio

Open the `apps/android` directory as the Gradle project. Generate the Kotlin
bindings and build the Rust libraries before running on a device.

## Supported ABIs

The build supports `arm64-v8a` and `x86_64`. Native libraries are generated
locally and are not embedded in source control. Packaging fails if either ABI
is missing `app/src/main/jniLibs/<abi>/liblorepia_uniffi.so`, preventing a
green build that would only fail when the app starts.

## Directory layout

```text
app/src/main/kotlin/dev/lorepia/app/
├── app/            App bootstrap and process-wide core lifecycle
├── bridge/         Kotlin CoreClient and the UniFFI adapter
├── feature/        Library, Import Review, Chat, and Settings UI state
├── platform/       Keystore credentials, document staging, and app directories
└── ui/             Navigation and Compose theme
```

Unit tests use a fake `CoreClient`; instrumentation tests exercise Compose and
the generated binding. Generated Kotlin is consumed from
`app/src/main/generated`.

## Troubleshooting

- `Unable to locate a Java Runtime`: set `JAVA_HOME` to a JDK 17 installation.
- `SDK location not found`: set `ANDROID_HOME` or add `sdk.dir=...` to the
  uncommitted `local.properties`.
- Missing `dev.lorepia.core` symbols: run the Kotlin binding generation script.
- `UnsatisfiedLinkError`: build the Rust libraries and verify that the device
  ABI matches a directory under `app/src/main/jniLibs`.
- A selected document disappears after inspection or closing Import Review:
  Android's source staging copy is intentionally removed after Rust has taken
  its verified private snapshot.
