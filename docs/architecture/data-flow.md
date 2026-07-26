# Data flow

## Commands

Native ViewModels send high-level commands such as `inspect_import`,
`commit_import`, `open_conversation`, or `send_message`. A binding maps the
request to a core use case. The core invokes the responsible Rust crate and
returns a stable DTO or stable error code.

## Events

Generation events carry `event_version`, `generation_id`, `conversation_id`, a
generation-scoped monotonically increasing `sequence`, emission time, and a
typed payload. A terminal event follows all buffered deltas. Late events are
ignored by native state when their generation identifier is no longer active.

No credential or raw provider response body is included in an event.
