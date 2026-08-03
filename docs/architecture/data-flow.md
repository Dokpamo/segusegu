# Data flow

## Commands

The Svelte frontend sends allowlisted, typed Tauri commands such as
`inspect_import`, `commit_import`, `open_conversation`, or `send_message`.
`shell-api` validates the bounded input and maps it to the current Core use case.
The core invokes the responsible Rust crate and returns a stable result or
stable error code; `shell-api` exposes only the UI projection needed by the
caller.

The frontend never sends SQL, raw provider requests, or unrestricted host paths.
It never receives a stored API credential. File selection produces an opaque
ticket for an app-owned bounded transport copy. Credential operations return
availability or failure state, while the platform plugin supplies plaintext
only to the authorized Rust operation for the minimum practical lifetime.

The retained native clients continue to use their high-level UniFFI/C ABI
adapters only as frozen compatibility and upgrade-test harnesses.

## Events

Generation events carry `event_version`, `generation_id`, `conversation_id`, a
generation-scoped monotonically increasing `sequence`, emission time, and a
typed payload. A terminal event follows all buffered deltas. Late events are
rejected when their generation, conversation, branch, lifecycle epoch, or
sequence no longer matches the receiving view.

The Tauri bridge carries high-rate generation output over one ordered Channel
per subscribed flow, not a global string event bus. Closing a view disposes its
listener and bridge task; it does not cancel the Core generation without an
explicit cancel command. A dropped or lagged Core event is a signal to reload
persisted messages and reconcile canonical state rather than guess missing
deltas.

Same-process generation reattachment is currently fail-closed. The registered
`subscribe_generation` command returns the stable, nonrecoverable
`generation_reattachment_unavailable` error without application state and
before registry, Shell, or Core access. The frontend does not call it during
persisted restoration or reconciliation; when a persisted generation is still
pending, the UI displays a blocking alert, retains the generation ID for
explicit cancellation, and does not enable a new send, edit, or regenerate
start. Initial send/edit/regenerate streams remain enabled because their
receiver is established before the generation starts.

Reattachment may be enabled only after Core can atomically validate that the
generation is live and owns the supplied conversation and branch while
returning status, a sequence watermark, and an already-established receiver, or
after an equivalent durable outbox exists. The current fail-closed path consumes
no bounded stream slot. The remaining product-parity requirement is tracked in
[the Core/Tauri contract matrix](../migrations/core-tauri-contract-matrix.md).

No credential, authorization header, private prompt body, unrestricted path, or
raw provider response body is included in a command result, Channel item,
stable error, or diagnostic event.
