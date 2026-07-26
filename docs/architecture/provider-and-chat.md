# Provider and chat

The chat crate constructs the final ordered message list from a character
definition and persisted history. Native apps never rebuild the final prompt.

The initial provider adapter supports OpenAI-compatible chat-completions
streaming. HTTPS is required except for loopback HTTP. URLs with embedded
credentials are rejected. A credential is passed to one request in memory and
is not persisted.

Each request receives a generation ID and cancellation channel. Provider deltas
are buffered through bounded channels, assigned a monotonic sequence, and
published as versioned events. The user message is committed before the
request; a completed assistant message is committed after the terminal provider
result.
