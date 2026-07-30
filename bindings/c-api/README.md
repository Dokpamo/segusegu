# C ABI binding

`include/lorepia.h` is the stable Windows interop contract. ABI version 3
exposes an opaque core handle, explicit UTF-8 pointer/length inputs, owned byte
buffers, structured last-error JSON, import/library/chat/settings commands, and
batched event polling. Callers release every returned buffer with
`lorepia_buffer_free` and every handle with `lorepia_core_destroy`.

ABI version 3 adds event-schema version 2 routing metadata to JSON event
batches. Event batches contain both `events` and `dropped_events`. When the
latter is non-zero, callers refresh the persisted conversation instead of
attempting to reconstruct missed token deltas. Credentials are accepted only
as per-command input and are never persisted by the Rust core.

Import inspection JSON includes nullable `representative_image` metadata
(`logical_asset_id`, `media_type`, and `size_bytes`) plus the bounded,
deterministically ordered `unsupported_optional_fields` array. These fields
contain no staging filesystem path or raw asset bytes.

The C# application must call this API only through `Lorepia.Native`.
