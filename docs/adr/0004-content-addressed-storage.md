# ADR 0004: Content-addressed storage

## Context

Imported packages can contain repeated large assets. SQLite is well suited to
relationships and transactions, but not to duplicating immutable package bytes.

## Decision

Persist immutable source packages and assets under SHA-256 paths while SQLite
stores metadata and relative references.

## Alternatives considered

- Store packages and assets as SQLite blobs: rejected because large immutable
  payloads complicate streaming, recovery, and database maintenance.
- Copy mutable files into each character directory: rejected because it wastes
  space and weakens integrity and deduplication guarantees.

## Consequences

Duplicate bytes share storage, paths remain portable, and integrity can be
rechecked. Cache deletion is independent. File placement and SQLite commit
require a recovery journal because they are not one atomic transaction.
