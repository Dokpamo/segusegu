# ADR 0002: Shared Rust core and native UI

## Decision

Put platform-independent domain, import, storage, chat, and provider behavior in
Rust. Use Compose, SwiftUI, and WinUI for native interfaces.

## Consequences

Behavioral policy is implemented once while each platform retains accessibility,
navigation, input, lifecycle, and OS integration. FFI contracts and native
artifact builds become explicit engineering responsibilities.
