# Platform bridges

## Kotlin and Swift

`lorepia-uniffi` exports records, stable errors, and an object owning one core.
Generated Kotlin and Swift sources are committed in explicit generated
directories. CI rebuilds them and fails on drift. Native libraries and
XCFrameworks are not committed.

The shared Import Review contract includes a nullable `representative_image`
record (`logical_asset_id`, `media_type`, `size_bytes`) and the bounded
`unsupported_optional_fields` list. Kotlin and Swift map those records into
native models without parsing packages or receiving staging paths or asset
bytes.

## C# and Windows

`bindings/c-api/include/lorepia.h` is the ABI contract. It uses:

- ABI version 2;
- an opaque core handle;
- status codes and out parameters;
- UTF-8 JSON for larger response DTOs;
- buffers allocated by Rust and released only by `lorepia_buffer_free`.

`Lorepia.Native` owns P/Invoke, `SafeHandle`, and buffer lifetime.
`Lorepia.App` does not call native methods directly.
The C ABI serializes the same Import Review fields as JSON, and the C# DTO
preserves their nullable/list semantics.
