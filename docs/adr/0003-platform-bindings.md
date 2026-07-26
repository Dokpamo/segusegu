# ADR 0003: Platform bindings

## Decision

Use one UniFFI crate for Kotlin and Swift. Use a versioned C ABI and P/Invoke for
C#.

## Consequences

Bindings expose only high-level core use cases. Generated Kotlin and Swift
sources are reproducible and drift-checked. Windows uses explicit handle and
buffer ownership rather than depending on Rust layout.
