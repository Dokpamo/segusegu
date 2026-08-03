# Frozen Android compatibility rules

- This directory is the frozen native Android compatibility, reference, and
  upgrade-test harness retained during the Tauri mainline migration.
- Do not add new product features here. Changes are limited to parity evidence,
  upgrade and data/credential continuity, security regressions, and maintenance
  required to keep the native baseline buildable until its removal gates pass.
- The production-client mainline lives under `apps/lorepia`. Do not implement
  Tauri frontend or plugin code in this directory.
- Keep the retained UI in Jetpack Compose only.
- Keep the retained Android lifecycle, document picking, and staging in the
  Android app.
- ViewModels must not parse character packages or access SQLite.
- Call Rust only through `CoreClient`; screens must not call generated bindings.
- Treat generated UniFFI Kotlin sources as read-only.
- Do not commit generated native libraries, APKs, `local.properties`, or build
  directories.
- Run `./gradlew test lint assembleDebug` for Android changes.
- A passing native build is baseline evidence only; it does not prove Tauri
  parity, production upgrade continuity, or release readiness.
