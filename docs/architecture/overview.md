# Architecture overview

Lorepia is a local-first application with one Tauri 2 product client and one
shared Rust application core. The packaged Svelte 5 frontend is common to
Android, iOS, macOS, and Windows; platform security and lifecycle services
remain native.

```text
Svelte / TypeScript UI
  -> typed frontend IPC client
  -> scoped Tauri application command or ordered Channel
  -> shell-api validation and UI projection
  -> lorepia-core use case
  -> content / storage / chat / providers
  -> versioned Core result or ChatEvent
  -> shell-api redaction and reconciliation
  -> frontend presentation state

apps/lorepia/src-tauri
  -> scoped lorepia-platform operation
  -> Keystore / Keychain / PasswordVault
     picker / lifecycle / notification / deep link / menu
```

## Ownership

### Svelte and TypeScript

- shared product UI and navigation;
- presentation state and responsive mobile/desktop composition;
- semantic accessibility markup;
- focus, keyboard, pointer, touch, selection, and IME-aware interaction; and
- listener disposal and rejection of stale view events.

The frontend does not implement domain rules or security review gates.

### Rust Core

- content-package inspection and import policy;
- SQLite persistence, migrations, immutable sources, and addressed assets;
- characters, conversations, branches, messages, and identifier semantics;
- prompt planning, generation, ordered events, and cancellation;
- provider discovery, networking, model and preset behavior, catalogs, and
  review gates; and
- validation and security-sensitive state.

The Core stays UI-free. Tauri adoption does not change existing Core meaning to
fit a preferred frontend data model.

### `shell-api`

- validates command input;
- maps current Core operations to bounded Tauri-safe DTOs;
- removes secrets and unrestricted paths;
- returns stable redacted error envelopes;
- transports ordered chat events; and
- attempts reconciliation of detected transient delivery loss from persisted
  Core state.

It is an adapter, not a second product domain layer.

### Tauri application adapter

`apps/lorepia/src-tauri` owns the command boundary. It composes a validated
`shell-api`/Core operation with the minimum required platform-plugin operation,
including picker staging and in-process credential compensation. This
coordination does not move product rules into the application layer.

### Platform Tauri plugins

- credentials in Android Keystore, Apple Keychain, and Windows PasswordVault;
- native file pickers and permission lifetimes;
- process, window, foreground/background, and shutdown lifecycle;
- notifications, deep links, menus, and other scoped OS services; and
- production identity, signing, packaging, and update integration.

A plugin exposes the minimum typed operation needed by the Tauri application
adapter. It does not expose a generic credential, filesystem, network, or shell
surface.

## Security boundaries

JavaScript never:

- opens SQLite;
- receives a raw API credential or authorization header;
- receives an unrestricted absolute file path;
- parses an imported content package;
- calls a provider endpoint directly; or
- bypasses a Core inspection, consent, review, or commit gate.

A file selection becomes an opaque import ticket after a bounded app-owned
transport copy. A credential operation returns availability or a redacted
failure state. Provider networking and content parsing stay in Rust.

Normal calls use scoped Tauri commands. High-rate generation deltas use an
ordered Channel carrying the current versioned Core event identity and
sequence. Persisted messages are authoritative after lag, listener disposal,
lifecycle transition, or process restart. Production Tauri currently keeps
same-process generation reattachment fail-closed: the registered command
returns a stable error before application state, the bounded bridge registry,
Shell, or Core can be reached, and the frontend does not invoke it. Re-enabling
reattachment requires Core to atomically validate the live
generation/conversation/branch route and combine persisted status, a sequence
watermark, and an already-established receiver. That release condition is
specified in
[the Core/Tauri contract matrix](../migrations/core-tauri-contract-matrix.md).

## Local data

There is no developer-operated backend. SQLite, immutable source packages, and
content-addressed assets remain under the existing platform Core root.
Credentials remain in the established OS credential store. The mainline does
not substitute Tauri's default app-data location for the existing roots.

Exact baseline identities, paths, formats, and versions are recorded in
[the frozen native baseline](../migrations/native-baseline.md).

## Migration state

Tauri 2 is the Accepted mainline architecture, not a shadow or experimental
client. Previous Compose, SwiftUI, WinUI, UniFFI, and C ABI code may remain in
this repository while it supplies parity and upgrade evidence. The full native
implementation is frozen independently at:

- repository: `https://github.com/Dokpamo/lorepia-native-reference`;
- tag: `native-baseline-before-tauri-2026-08-02`; and
- commit: `66e398fa6256f17b04c82569e6764a9e5332265c`.

Release readiness and native-source removal are separate gates documented in
[the Tauri mainline migration](../migrations/tauri-mainline-migration.md).

Arbitrary Creator scripts are outside this architecture decision. The approved
direction starts with a future Rust-validated declarative format described in
[the Creator platform roadmap](../roadmaps/creator-platform-roadmap.md).
