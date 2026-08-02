# C ABI binding

`include/lorepia.h` is the stable Windows interop contract. ABI version 7
exposes an opaque core handle, explicit UTF-8 pointer/length inputs, owned byte
buffers, structured last-error JSON, import/library/chat/settings commands, and
batched event polling. Callers release every returned buffer with
`lorepia_buffer_free` and every handle with `lorepia_core_destroy`.

ABI version 7 includes provider discovery, reviewed model synchronization,
two-phase signed-catalog import and rollback, typed catalog diffs, and
candidate preset validation/reasoning/cache/request-preview commands. Model
sync events are polled per job and acknowledged by exact job/sequence; there
is no cross-job drain. Chat event batches contain both `events` and
`dropped_events`. When the latter is non-zero, callers refresh the persisted
conversation instead of attempting to reconstruct missed token deltas.
Credentials are accepted only as transient command input and are never
persisted by the Rust core.

Provider-discovery snapshots, events, approvals, review changes, progress,
warnings, evidence kinds, and compensation records are serialized from closed
Rust enums. Snapshot schema version 3 also carries the typed, secret-free
setup-assistant resume boundary: checkpoint, exact next action, questions, and
optional draft review. It includes the exact persisted, secret-free connection
options so a restarted client reuses the same values, API base path, timeout,
network mode, and finite local-network approval for supplemental inspection.
Native callers do not infer restart behavior from the overall discovery state
or opaque draft JSON. The setup-assistant runner executes tool calls inside
Core and returns only `request_more_evidence` or `review_draft`; native callers
cannot submit tool results or inject internal completion actions. A
`resume_core_host_action` boundary is resumed through a dedicated Core-owned
operation which restores the allowlisted tool and submits its typed result
internally.

Import inspection JSON includes nullable `representative_image` metadata
(`logical_asset_id`, `media_type`, and `size_bytes`) plus the bounded,
deterministically ordered `unsupported_optional_fields` array. These fields
contain no staging filesystem path or raw asset bytes.

The C# application must call this API only through `Lorepia.Native`.
