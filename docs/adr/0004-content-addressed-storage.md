# ADR 0004: Content-addressed storage

## Decision

Persist immutable source packages and assets under SHA-256 paths while SQLite
stores metadata and relative references.

## Consequences

Duplicate bytes share storage, paths remain portable, and integrity can be
rechecked. Cache deletion is independent. File placement and SQLite commit
require a recovery journal because they are not one atomic transaction.
