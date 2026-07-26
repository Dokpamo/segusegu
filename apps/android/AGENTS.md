# Android rules

- Build the UI with Jetpack Compose only.
- Keep Android lifecycle, document picking, and staging in the Android app.
- ViewModels must not parse character packages or access SQLite.
- Call Rust only through `CoreClient`; screens must not call generated bindings.
- Treat generated UniFFI Kotlin sources as read-only.
- Do not commit generated native libraries, APKs, `local.properties`, or build
  directories.
- Run `./gradlew test lint assembleDebug` for Android changes.
