# UniFFI binding

This crate is the only Kotlin and Swift FFI boundary. Product logic remains in
`lorepia-core`.

The binding exposes the complete high-level core contract:

- version and health information;
- import inspection, approval, discard, character lookup, and database counts;
- conversation creation, conversation/message listing, sending, cancellation,
  and bounded non-blocking event polling;
- provider profile CRUD and application settings.

`poll_events` accepts a batch size from 1 through 256. Each event includes the
core event version, generation ID, conversation ID, and per-generation
sequence. A non-zero `dropped_event_count` means the platform must refresh the
persisted message list before applying later deltas.

Provider credentials are accepted only as a transient `send_message` argument.
They are not part of provider profiles, settings, events, or errors.

Errors keep the stable core error code, human-readable detail, recoverability
flag, and operation ID. Import warnings remain structured code/message records.
Import inspections expose nullable representative-image metadata and the
bounded, sorted list of unsupported optional CCv3 `data` fields. The image
record contains only a validated archive logical identifier, media type, and
size; native bindings never receive staging paths or image bytes.
Timestamps are RFC 3339 strings. `version_info` reports the core, binding, and
chat-event contract versions; the complete native application contract starts
at binding API version 2.

Generate bindings through `cargo xtask bindings kotlin` or
`cargo xtask bindings swift`. Generated source is committed for IDE builds but
must never be edited by hand. Native libraries and XCFrameworks are build
artifacts and are not committed.

This crate uses UniFFI proc-macro metadata (`setup_scaffolding!` and exported
Rust records/functions), so there is no separately maintained UDL file.
