# ADR 0005: Import trust boundary

## Decision

Treat every selected package as hostile. A native app may only stage bounded
bytes. Rust inspection must complete and present a review before commit, and the
source hash must match again at commit.

## Consequences

Archive traversal, absolute paths, symbolic links, normalization collisions,
decompression abuse, and malformed metadata are rejected consistently on every
platform. Import remains a two-step API instead of a convenience copy.
