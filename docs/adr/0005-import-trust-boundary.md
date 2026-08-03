# ADR 0005: Import trust boundary

## Status

Accepted. The trust boundary is unchanged by the
[Tauri primary-client decision](../architecture/decisions/ADR-0006-adopt-tauri-primary-client.md).

## Context

Picker input can be malformed, hostile, or changed after selection. Every
platform needs the same archive limits and review-before-commit behavior.

## Decision

Treat every selected package as hostile. The first-party platform integration
may only copy bounded bytes into app-owned transport staging. In the Tauri
mainline, the Svelte frontend receives an opaque import ticket and safe metadata,
not an unrestricted absolute path. `shell-api` resolves the ticket internally
and passes the staged source to Rust. Rust inspection must complete and present
a structured review before commit, and the source hash must match again at
commit.

The frozen native compatibility harnesses retain their existing bounded staging
flows for parity and upgrade evidence. They may not weaken this decision while
they remain in the repository.

## Alternatives considered

- Parse packages independently in each native app: rejected because validation
  policy and archive behavior would diverge.
- Give the frontend a selected absolute path: rejected because it expands the
  webview filesystem boundary and leaks a host identifier the UI does not need.
- Extract directly into permanent storage in one step: rejected because it
  bypasses review and exposes storage to traversal, decompression, and TOCTOU
  risks.

## Consequences

Archive traversal, absolute paths, symbolic links, normalization collisions,
decompression abuse, and malformed metadata are rejected consistently on every
platform. Import remains a two-step API instead of a convenience copy.
