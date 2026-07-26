# Android development

See `apps/android/README.md` for pinned SDK versions and commands.

The Android app is one Gradle module. Kotlin owns document selection, staging,
credentials, navigation, accessibility, and lifecycle. `CoreClient` isolates
ViewModels from generated UniFFI code.

Generate bindings and native libraries before building:

```bash
./scripts/build-android.sh
```
