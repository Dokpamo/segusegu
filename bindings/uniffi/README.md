# UniFFI binding

This crate is the only Kotlin and Swift FFI boundary. Product logic remains in
`lorepia-core`.

The binding exposes the complete high-level core contract:

- version and health information;
- import inspection, approval, discard, character lookup, and database counts;
- explicit multi-room creation and character-scoped room lookup;
- conversation state, branch creation/selection, active-lineage message
  listing, chat/story mode selection, expected-head sending, immutable
  edit/regeneration branches, logical branch removal, cancellation, and bounded
  non-blocking event polling;
- provider profile CRUD and application settings.

`poll_events` accepts a batch size from 1 through 256. Each event includes the
core event version, generation ID, conversation ID, branch ID, pending
assistant message ID, and per-generation sequence. A non-zero
`dropped_event_count` means the platform must refresh the persisted active
branch before applying later deltas.

Provider credentials are accepted only as transient send, edit, or regenerate
arguments. They are not part of provider profiles, settings, events, or errors.

Errors keep the stable core error code, human-readable detail, recoverability
flag, and operation ID. Import warnings remain structured code/message records.
Import inspections expose nullable representative-image metadata and the
bounded, sorted list of unsupported optional CCv3 `data` fields. The image
record contains only a validated archive logical identifier, media type, and
size; native bindings never receive staging paths or image bytes.
Timestamps are RFC 3339 strings. `version_info` reports the core, binding, and
chat-event contract versions. Message edit and regeneration create and select a
new branch without rewriting the source lineage. Removing a message rewinds
only the selected branch head; shared message rows and sibling branches remain
intact. Every mutation validates the caller's expected branch head. These
message-action APIs are binding API version 4; chat events remain version 2.

Generate bindings through `cargo xtask bindings kotlin` or
`cargo xtask bindings swift`. Generated source is committed for IDE builds but
must never be edited by hand. Native libraries and XCFrameworks are build
artifacts and are not committed.

This crate uses UniFFI proc-macro metadata (`setup_scaffolding!` and exported
Rust records/functions), so there is no separately maintained UDL file.
