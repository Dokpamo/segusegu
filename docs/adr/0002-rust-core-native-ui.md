# ADR 0002: Shared Rust core and native UI

## Context

Import safety, persistence, and chat semantics must remain consistent across
four platforms, while interaction and operating-system integration differ.

## Decision

Put platform-independent domain, import, storage, chat, and provider behavior in
Rust. Use Compose, SwiftUI, and WinUI for native interfaces.

## Alternatives considered

- Reimplement product rules in every native language: rejected because behavior
  and security policy would drift.
- Use one cross-platform UI runtime: rejected because native accessibility,
  navigation, lifecycle, and desktop conventions are product requirements.

## Consequences

Behavioral policy is implemented once while each platform retains accessibility,
navigation, input, lifecycle, and OS integration. FFI contracts and native
artifact builds become explicit engineering responsibilities.
