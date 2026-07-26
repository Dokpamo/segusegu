# Platform bridges

## Kotlin and Swift

`lorepia-uniffi` exports records, stable errors, and an object owning one core.
Generated Kotlin and Swift sources are committed in explicit generated
directories. CI rebuilds them and fails on drift. Native libraries and
XCFrameworks are not committed.

## C# and Windows

`bindings/c-api/include/lorepia.h` is the ABI contract. It uses:

- ABI version 1;
- an opaque core handle;
- status codes and out parameters;
- UTF-8 JSON for larger response DTOs;
- buffers allocated by Rust and released only by `lorepia_buffer_free`.

`Lorepia.Native` owns P/Invoke, `SafeHandle`, and buffer lifetime.
`Lorepia.App` does not call native methods directly.
