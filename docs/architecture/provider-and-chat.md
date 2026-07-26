# Provider and chat

The chat crate constructs the final ordered message list from a character
definition and persisted history. Native apps never rebuild the final prompt.

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

The initial provider adapter supports OpenAI-compatible chat-completions
streaming. HTTPS is required except for loopback HTTP. URLs with embedded
credentials are rejected. A credential is passed to one request in memory and
is not persisted.

Each request receives a generation ID and cancellation channel. Provider deltas
are buffered through bounded channels, assigned a monotonic sequence, and
published as versioned events. The user message is committed before the
request and a pending assistant row records in-flight work. After the provider
finishes, the assistant row is committed before `message_committed` and the
terminal generation event are published. When partial-generation preservation
is enabled, accepted text is also checkpointed while streaming at roughly
500-millisecond intervals or each additional 64 KiB, whichever comes first.
When it is disabled, streamed text is never written to the pending row. On
restart, preserved pending rows are marked cancelled and non-preserved pending
rows are removed.

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
