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

SQLite stores structured data and relative paths. Source and extracted asset
files are logically immutable and deduplicated by SHA-256. Cache lifetime is
independent from source and asset lifetime.

CAS publication copies and hashes into an exclusive temporary file, syncs that
file, and atomically renames it with no-replace semantics. It then syncs the
published file and its hash-prefix directory before SQLite may add the
corresponding records or delete the import journal. Linux, Android, and Apple
targets use native no-replace rename operations; other targets use an
equivalent no-clobber link fallback. Directory syncing is enforced on Unix.
Windows also attempts a directory-handle flush, but filesystems that reject
directory flushing still retain the mandatory CAS file flush.

Owned storage directories and CAS hash-prefix directories are checked with
non-following metadata. A symlink or other non-directory in that hierarchy is
reported as `storage_corrupted`; import and recovery never traverse it.

The schema stores characters, sources, assets, character-to-asset roles,
conversation rooms, parent-linked messages, branches, per-room active
branch/mode state, generation snapshots, non-secret provider profiles,
application settings, and import jobs. A version-3 migration converts each
legacy room's timestamp-ordered messages into one safe default lineage before
creating its root branch and `chat` state. WAL and foreign keys are enabled.

Branch publication uses an expected-head comparison in the same SQLite
transaction that inserts the user message, pending assistant message, and
generation. Branch rows point at their current head while messages retain their
parent, so common ancestors are shared and sibling histories remain isolated.

A file and SQLite cannot share one transaction, so the import journal records
source and asset hashes for deterministic cleanup after an interrupted
cross-resource commit. An inspection is removed from the in-memory review map
when commit or discard claims it, so concurrent commit/commit and
commit/discard races have one winner. A failed commit restores the review only
after a database read proves that its character was not committed.
