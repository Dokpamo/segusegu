# UniFFI binding

This crate is the only Kotlin and Swift FFI boundary. Product logic remains in
`lorepia-core`.

Generate bindings through `cargo xtask bindings kotlin` or
`cargo xtask bindings swift`. Generated source is committed for IDE builds but
must never be edited by hand. Native libraries and XCFrameworks are build
artifacts and are not committed.
