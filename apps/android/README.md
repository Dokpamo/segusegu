# LorePia for Android

## Overview

LorePia is a local-first native AI character chat application. The Android app
is a single Kotlin and Jetpack Compose module. It owns Android UI, navigation,
document picking, bounded staging copies, accessibility, and lifecycle. Rust
owns content inspection, persistence, chat behavior, and provider orchestration.

The app opens one `LorepiaCore` per process and exposes the real core version,
structured health report, character library, import workflow, persisted
conversations, chat events, provider profiles, and application settings.
Character files selected through Android's document picker are copied to an
app-only staging directory with a 50 MiB limit. Rust takes its own verified
inspection snapshot and returns structured warnings, blocked reasons, and an
estimated stored size. Only explicit user approval calls `commitImport`;
leaving before approval calls `discardImport` and removes Android's staged
copy.

Selecting a character opens its existing conversations or creates the first
one. The Chat screen restores persisted messages, submits through the selected
provider profile, polls bounded event batches, rejects stale generation or
sequence events, streams text, and exposes cancellation. Because the binding
event queue is process-wide, Chat also reconciles persisted messages after
dropped events, repeated empty batches, and route resume; a generation is
cleared when its pending persisted row is gone. Provider credentials are never
placed in Rust storage or ordinary preferences: Android encrypts them with a
non-exportable Android Keystore AES-GCM key and stores ciphertext in the app's
no-backup directory.

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
