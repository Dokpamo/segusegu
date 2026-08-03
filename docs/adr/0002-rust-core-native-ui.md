# ADR 0002: Shared Rust core and native UI

- Status: Superseded
- Superseded by:
  [ADR-0006: Adopt Tauri 2 as Lorepia's Primary Cross-Platform Client](../architecture/decisions/ADR-0006-adopt-tauri-primary-client.md)

## Historical context

Import safety, persistence, and chat semantics had to remain consistent across
four platforms while interaction and operating-system integration differed.

## Historical decision

Put platform-independent domain, import, storage, chat, and provider behavior in
Rust. Use Compose, SwiftUI, and WinUI for native interfaces.

## Alternatives considered at the time

- Reimplement product rules in every native language: rejected because behavior
  and security policy would drift.
- Use one cross-platform UI runtime: rejected because native accessibility,
  navigation, lifecycle, and desktop conventions were treated as product
  requirements.

## Historical consequences

Behavioral policy was implemented once while each platform retained
accessibility, navigation, input, lifecycle, and OS integration. FFI contracts
and native artifact builds became explicit engineering responsibilities.

## Superseding decision

The Rust ownership decision remains in force, but the UI decision does not.
Starting 2026-08-02, the main product client is the Tauri 2 application under
`apps/lorepia`. Svelte/TypeScript owns the shared UI while narrow native Tauri
plugins retain credential, file-picker, lifecycle, notification, deep-link,
menu, and other OS-service boundaries.

The native implementation described here is frozen at
`native-baseline-before-tauri-2026-08-02` in
`https://github.com/Dokpamo/lorepia-native-reference`. It is a behavioral,
upgrade, and rollback reference, not a parallel product line.
