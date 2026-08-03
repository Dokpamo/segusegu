# ADR 0003: Platform bindings

## Status

Superseded for primary-client development by the
[Accepted Tauri-primary-client decision](../architecture/decisions/ADR-0006-adopt-tauri-primary-client.md).
It remains active only for the frozen native compatibility and upgrade-test
harnesses until their removal gates pass.

## Context

Kotlin and Swift can share generated bindings, while .NET needs an ABI with
explicit ownership that remains stable independently of Rust layout.

## Historical decision

Use one UniFFI crate for Kotlin and Swift. Use a versioned C ABI and P/Invoke for
C#.

The Tauri mainline does not add new product behavior through these bindings.
Its Svelte frontend calls allowlisted typed Tauri commands or receives ordered
Tauri Channels. `shell-api` maps that boundary to the current high-level Core
contract, and first-party platform plugins provide native services. UniFFI and
the C ABI remain only while native parity and upgrade fixtures still depend on
them.

## Alternatives considered

- Hand-maintain JNI and Swift C wrappers: rejected because duplicate conversion
  and lifetime code would enlarge the unsafe boundary.
- Expose Rust structs directly to .NET: rejected because Rust layout and
  allocator ownership are not a stable C contract.

## Consequences

Bindings expose only high-level core use cases. Generated Kotlin and Swift
sources are reproducible and drift-checked. Windows uses explicit handle and
buffer ownership rather than depending on Rust layout.

During migration, binding changes require a concrete compatibility or upgrade
need and the existing drift checks. They must not become a second mainline API
or a place for new product logic. Removal is a separate cleanup after all
remaining contract coverage has moved to `shell-api` and Tauri integration
tests.
