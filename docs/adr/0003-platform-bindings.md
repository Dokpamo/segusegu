# ADR 0003: Platform bindings

## Context

Kotlin and Swift can share generated bindings, while .NET needs an ABI with
explicit ownership that remains stable independently of Rust layout.

## Decision

Use one UniFFI crate for Kotlin and Swift. Use a versioned C ABI and P/Invoke for
C#.

## Alternatives considered

- Hand-maintain JNI and Swift C wrappers: rejected because duplicate conversion
  and lifetime code would enlarge the unsafe boundary.
- Expose Rust structs directly to .NET: rejected because Rust layout and
  allocator ownership are not a stable C contract.

## Consequences

Bindings expose only high-level core use cases. Generated Kotlin and Swift
sources are reproducible and drift-checked. Windows uses explicit handle and
buffer ownership rather than depending on Rust layout.
