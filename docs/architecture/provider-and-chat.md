# Provider and chat

The chat crate constructs the final ordered message list from a character
definition and persisted branch history. Native apps never rebuild the final
prompt.

A character can own multiple conversation rooms. Every room has one selected
`chat` or `story` mode and one active branch. Messages form a parent-linked
lineage rather than a flat transcript. Creating a branch records its fork
message without copying the shared ancestors; selecting a branch changes only
the room's active-lineage pointer. Prompt history follows that parent chain, so
messages from sibling branches never leak into a request.

Sending to a branch includes its expected head. SQLite atomically checks that
head while appending the user message, pending assistant message, and
generation record. A stale writer fails instead of silently splicing two
histories together. The generation snapshots the selected mode so changing the
room control later cannot reinterpret an in-flight or restored request. Chat
mode requests concise character dialogue, while story mode requests scene-led
prose and dialogue without taking control of the user's choices.

Message actions preserve that immutable lineage. Editing a complete user
message creates and selects a new branch from its parent, then appends the
replacement user message and a new pending response. Regenerating an assistant
response creates and selects a new branch from the source user's parent, copies
the user text into a new message, and starts a new response. The original branch
and its message records do not change. Removing a user or assistant message is
a logical operation: it rewinds the selected branch head to the target's parent,
so the target and its later suffix disappear only from that branch. All three
operations require the active branch and its expected head to still match and
are rejected while that branch has a pending generation.

Core applies finite request and response budgets before anything reaches a
provider or the message database:

- user text: 65,536 UTF-8 bytes and 16,384 Unicode scalars;
- prompt: 128 messages, 524,288 UTF-8 bytes, and 131,072 Unicode scalars;
- each loaded history row: 262,144 UTF-8 bytes and 65,536 Unicode scalars;
- requested provider output: 4,096 tokens;
- cumulative streamed text plus reasoning: 262,144 UTF-8 bytes and 65,536
  Unicode scalars.

Prompt planning keeps the most recent suffix that fits. The newest user
message must fit and is rejected with `invalid_input` before persistence if it
does not. Legacy oversized rows are filtered by SQLite length predicates
before Rust materializes them. If a provider ignores the requested token limit,
the stream stops before the first delta that would cross the cumulative bound
and emits `provider_unavailable` with the stable message `provider output
exceeded the 262144-byte or 65536-character safety limit`. The partial
generation preference then determines whether the already accepted prefix is
stored.

Provider-template presentation includes a Rust-derived
`default_network_mode`. It comes from the compiled adapter descriptor, not
persisted template JSON or native family-name inference: Ollama defaults to
`local_loopback`, while the other built-in families default to `public`.

The compiled adapter registry covers OpenAI Responses, OpenAI-compatible Chat
Completions, Anthropic Messages, Gemini Generate Content, OpenRouter, and
Ollama's native API. Provider connections persist a template/version, display
name, canonical API origin and optional base path, typed provider-specific
connection fields, timeout, network mode, credential reference and exact
credential scope, and the last connection status. The API key itself remains
only in the native OS credential vault. Model IDs and generation controls are
separate route and preset records populated by the reviewed model-sync flow.

Public connections require HTTPS. `local_loopback` accepts only loopback
origins. `approved_local_network` requires a separately reviewed grant binding
one exact origin to 1–16 normalized, unique RFC1918 IPv4 or ULA IPv6 addresses;
the grant is immutable for that connection and has a relational audit mirror.
A generic “local” boolean can migrate only to loopback mode and can never
create a LAN grant. URLs with embedded credentials are rejected, redirects do
not inherit credentials, and a credential is released after the request rather
than entering Rust persistence.

OpenAI-compatible chat streams must report a supported `finish_reason` before
`[DONE]`; `stop`, `length`, and `content_filter` are terminal successes, while
`tool_calls` and `function_call` remain unsupported for that legacy adapter.
`[DONE]` alone does not complete a generation.

Each request receives a generation ID and cancellation channel. Provider deltas
are buffered through bounded channels, assigned a monotonic sequence, and
published as versioned events. Every event carries the room ID plus the branch
and pending assistant IDs, allowing a native client to reject a valid event
that belongs to a different visible branch. The user message is committed
before the request and a pending assistant row records in-flight work. After
the provider finishes, the assistant row is committed before
`message_committed` and the terminal generation event are published. When
partial-generation preservation is enabled, accepted text is also checkpointed
while streaming at roughly 500-millisecond intervals or each additional 64
KiB, whichever comes first. When it is disabled, streamed text is never
written to the pending row. On restart, preserved pending rows are marked
cancelled and non-preserved pending rows are removed.

Terminal assistant and generation state is committed in one SQLite
transaction. If that transaction rejects provider usage or otherwise fails,
Core attempts a separate compensation transaction that marks both records
failed, clears unpersistable usage, and stores only the stable
`storage_unavailable` code. Raw storage errors and credentials are never
written into the conversation or event stream. A compensated branch has no
pending assistant and can accept the next send.

Provider usage persistence includes input, output, cache-read, cache-write,
reasoning, and tool token counters plus a 4 KiB canonical object containing
only adapter-recognized numeric summary fields. Every counter is converted to
SQLite's signed integer range before the terminal transaction starts, so one
overflow leaves the generation running for the same compensation path rather
than partially committing usage.

Opaque provider reasoning topology and storage schemas remain internal,
bounded, typed, and dormant so a future release can adopt them without accepting
unstructured payloads. The current release advertises preservation off and
rejects candidates that enable it before save, preview, provider construction,
or network access. In addition, a target whose connection has a
`credential_ref`, or any call carrying a non-empty raw credential, forcibly
disables capture, persistence, and replay even if a legacy preset requested
preservation. Existing typed rows may remain for migration compatibility, but
Core never loads them into such a request and never writes newly returned state
for it. This prevents continuity captured under one credential from crossing to
another credential that uses the same route. Opaque payloads never become
`ChatEvent` values, UI data, log/debug text, error text, or request previews.

A provider connection's template, origin, API base path, connection values,
network approval, and credential binding form its immutable endpoint identity.
Renaming the connection or changing its timeout is allowed. Changing any
endpoint-affecting field requires a new connection and therefore new model
routes, preventing stored opaque state from crossing to a different upstream.

Generation preset candidates pass the same effective catalog, capability
dialect, family-specific parameter mapping, and route request-plan gate before
Core writes them. Validation failure leaves the previous preset graph
unchanged. Stored and unsaved-candidate request previews reuse that gate and
the selected adapter's endpoint/body rules; previews contain only the method,
canonical origin, safe path, header names, and scalar-free body shape.

The async runtime is created and destroyed by a dedicated owner thread.
Dropping the last core handle cancels every active generation, allows a bounded
cooperative drain, and then performs a bounded runtime shutdown. Generation
tasks hold only the storage, event, and cancellation state they need, so they
cannot become the owner that destroys their own runtime. Request credentials
and provider objects are released as soon as their generation finishes or is
forced down.

Native clients poll bounded event batches, reject stale sequence numbers, and
refresh persisted messages whenever the binding reports dropped events.
Provider profiles contain only non-secret endpoint and model settings.
Credentials are supplied from an OS credential store for one request and never
enter Rust persistence. Profile IDs, display names, base URLs, and model names
also have finite byte and character limits enforced before SQLite writes:
256/64, 512/128, 4,096/1,024, and 1,024/256 respectively.

The implemented provider-discovery and model-catalog architecture is recorded in
[Provider Discovery, Model Catalog, and AI Setup Assistant](provider-discovery-and-model-catalog.md).
Its durable discovery, model-sync review, catalog, adapter, capability,
parameter, credential, and native-UI contracts are normative for current
behavior.
