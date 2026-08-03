# Local storage

The trusted Tauri host supplies an app-owned root and Rust creates the same
relative layout on every platform. Production configurations must resolve the
exact root used by the corresponding native baseline; they do not silently
adopt a framework-default Tauri data path. Development builds use a separate
identity and root so they can coexist with the baseline.

The Svelte frontend never receives the root, a SQLite path, or an unrestricted
asset path and never opens SQLite. `shell-api` may expose only opaque identifiers
and bounded asset metadata. The frozen native clients continue to supply their
existing roots for compatibility and old-to-new upgrade fixtures.

```text
.lorepia-owner.lock
db/lorepia.sqlite3
sources/sha256/<prefix>/<digest>
assets/sha256/<prefix>/<digest>
cache/
staging/
recovery/
```

Opening storage canonicalizes the app-owned root, rejects a root or owner-lock
symbolic link, and acquires a non-blocking OS-level exclusive owner lock before
opening SQLite, migrating, recovering, or cleaning staging. The lock is held
for the full `Storage` lifetime and released automatically on normal exit or
process termination. A second process receives recoverable
`storage_unavailable` and cannot run recovery against work owned by the first
process.

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
legacy room into one safe default lineage before creating its root branch and
`chat` state. It first pairs each assistant with its persisted user parent,
then orders whole turns with deterministic tie breakers. The legacy graph is
validated before the destructive table replacement. WAL and foreign keys are
enabled.

Provider connection removal is an archive operation, not a physical delete.
Archived connections disappear from active connection/profile reads and cannot
be used for generation or model synchronization. The same connection identity
cannot be reused. Archiving also clears an active selection atomically, while
model routes, presets, completed-generation provenance, model-sync history, and
provider-discovery audit rows remain intact across database reopen.

Archiving fails with a recoverable `invalid_input` while that connection has
any nonterminal model-sync job or provider-discovery session. The user must
finish, cancel, or explicitly reconcile that durable work first. This keeps the
connection visible through the same active list used to rediscover its work;
terminal job and discovery history does not prevent a later archive and remains
readable afterward.

An approved LAN connection stores its typed exact-origin/address grant inside
the secret-free connection config and in an immutable relational audit mirror.
Storage rejects a missing or divergent mirror on open. Public and loopback
connections cannot carry this grant, and an existing connection cannot change
its API origin, network mode, or approved address set.

Generation snapshots also store exact provider family/route/preset provenance,
expanded usage counters, a bounded recognized usage-summary object, and may
retain a bounded typed array of legacy provider-native opaque reasoning state.
SQLite guards require the family to match the referenced route and prohibit
opaque state on non-complete rows or without complete route and preset
provenance. Hydration revalidates the typed JSON and its count and serialized
byte limits, but storage validity is not replay authorization. The current Core
keeps this schema dormant and never loads or newly persists opaque state for a
connection with a `credential_ref` or a call carrying a non-empty raw
credential.

Branch publication uses an expected-head comparison in the same SQLite
transaction that inserts the user message, pending assistant message, and
generation. Branch rows point at their current head while messages retain their
parent, so common ancestors are shared and sibling histories remain isolated.

Edit and regeneration publish a new branch, replacement user message, pending
assistant message, generation record, and active-branch selection in one
transaction after revalidating the source lineage and expected head. Logical
message removal updates only the selected branch head with the same compare-and-
swap guard. It never deletes shared message rows, and therefore cannot corrupt a
sibling branch that still reaches them.

A file and SQLite cannot share one transaction, so the import journal records
source and asset hashes for deterministic cleanup after an interrupted
cross-resource commit. An inspection is removed from the in-memory review map
when commit or discard claims it, so concurrent commit/commit and
commit/discard races have one winner. A failed commit restores the review only
after a database read proves that its character was not committed.

## Diagnostics and redaction

The Rust provider, discovery, and storage layers currently configure no
production logger or log sink and emit no production log records. The
redacted-logging unit-test item and the log leg of the credential-leak scan are
therefore not applicable to the current implementation. This is an
implementation fact, not permission to log raw state.

Any future logging boundary must accept only a dedicated typed, bounded,
secret-free redacted projection. It must not accept raw credentials, secret
cURL input, provider response bodies, discovery drafts, event JSON, or database
rows. Adding a production log sink also requires a project-owned credential
canary test that captures that sink and verifies the same canary is absent from
SQLite, returned errors, versioned events, and logs.
