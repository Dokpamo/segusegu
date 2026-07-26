# Local storage

Every native app supplies an app-owned root. Rust creates the same relative
layout on every platform:

```text
db/lorepia.sqlite3
sources/sha256/<prefix>/<digest>
assets/sha256/<prefix>/<digest>
cache/
staging/
recovery/
```

SQLite stores structured data and relative paths. Source files are immutable and
deduplicated by SHA-256. Cache lifetime is independent from source lifetime.

The initial schema stores characters, sources, assets, conversations, messages,
non-secret provider profiles, application settings, and import jobs. WAL and
foreign keys are enabled. A file and SQLite cannot share one transaction, so an
import journal records the cross-resource state for deterministic recovery.
