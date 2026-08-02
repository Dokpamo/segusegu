# Platform bridges

## Kotlin and Swift

`lorepia-uniffi` exports records, stable errors, and an object owning one core.
Generated Kotlin and Swift sources are committed in explicit generated
directories. CI rebuilds them and fails on drift. Native libraries and
XCFrameworks are not committed. The current binding API version is 8.

Wire contracts use independent monotonic versions. A breaking core behavior
change increments the Core API version. A breaking UniFFI DTO or method change
increments the binding API version and regenerates both generated trees. A
breaking chat event shape increments the chat-event version; if that event is
also exposed through C JSON, the C ABI version increments as part of the same
change. Native clients must reject unsupported versions instead of guessing.

The shared Import Review contract includes a nullable `representative_image`
record (`logical_asset_id`, `media_type`, `size_bytes`) and the bounded
`unsupported_optional_fields` list. Kotlin and Swift map those records into
native models without parsing packages or receiving staging paths or asset
bytes.

Provider-discovery snapshot schema version 3 exposes the setup assistant's
durable resume boundary as closed checkpoint and action enums plus typed
questions and an optional draft review. Kotlin and Swift render that exact
action after restart; they do not infer it from the aggregate discovery state.
The same snapshot carries the exact secret-free connection options persisted
at begin so supplemental inspection cannot silently fall back to a different
network mode, LAN grant, API base path, timeout, or provider-specific value.
A `resume_core_host_action` boundary is continued only by the dedicated
Core-owned method; native code never receives or submits raw assistant tool
payloads.

## C# and Windows

`bindings/c-api/include/lorepia.h` is the ABI contract. It uses:

- ABI version 7, including provider discovery, job-scoped model-sync events,
  two-phase catalog activation/rollback, typed catalog diffs, and candidate
  preset controls;
- an opaque core handle;
- status codes and out parameters;
- UTF-8 JSON for larger response DTOs;
- buffers allocated by Rust and released only by `lorepia_buffer_free`.

`Lorepia.Native` owns P/Invoke, `SafeHandle`, and buffer lifetime.
`Lorepia.App` does not call native methods directly.
The C ABI serializes the same Import Review fields as JSON, and the C# DTO
preserves their nullable/list semantics.

Provider-discovery snapshot schema version 3 carries the same typed
setup-assistant resume boundary and persisted connection options for Windows.
The C ABI never exposes raw assistant tool-result submission or provider
opaque-reasoning payloads.

Windows provider credentials remain in PasswordVault and are addressed by
profile ID. Changing the profile being edited clears and invalidates any
credential draft before the new metadata is loaded. A credential write
captures its target profile before asynchronous persistence, so a later
selection change cannot retarget the secret.
