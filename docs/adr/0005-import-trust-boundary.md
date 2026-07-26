# ADR 0005: Import trust boundary

## Context

Picker input can be malformed, hostile, or changed after selection. Every
platform needs the same archive limits and review-before-commit behavior.

## Decision

Treat every selected package as hostile. A native app may only stage bounded
bytes. Rust inspection must complete and present a review before commit, and the
source hash must match again at commit.

## Alternatives considered

- Parse packages independently in each native app: rejected because validation
  policy and archive behavior would diverge.
- Extract directly into permanent storage in one step: rejected because it
  bypasses review and exposes storage to traversal, decompression, and TOCTOU
  risks.

## Consequences

Archive traversal, absolute paths, symbolic links, normalization collisions,
decompression abuse, and malformed metadata are rejected consistently on every
platform. Import remains a two-step API instead of a convenience copy.
