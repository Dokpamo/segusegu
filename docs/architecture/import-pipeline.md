# Import pipeline

```text
OS picker -> native bounded staging -> Rust-owned snapshot -> inspect
          -> review -> approve -> commit
```

The native application owns the picker, its bounded stream copy, progress,
cancellation, and partial-file cleanup. Rust makes a second bounded snapshot in
its owned data root so the picker source cannot change between review and
commit. Rust then verifies the file signature, format, archive paths, entry
count, individual and total size, compression ratio, normalized collisions,
symbolic links, metadata, and asset signatures.
An asset whose declared extension does not match its file signature remains
visible in Import Review with a warning and a concrete blocked reason, but it
cannot be committed and its contents are not extracted to asset staging.

Default hard limits are:

| Limit | Value |
|---|---:|
| Source file | 128 MiB |
| Archive entries | 2,048 |
| One entry | 64 MiB |
| Total uncompressed | 512 MiB |
| Compression ratio | 100:1 |
| Character metadata | 4 MiB |

Within the metadata object, the trimmed character name is limited to 1,024
UTF-8 bytes and 256 Unicode scalars. The trimmed description is limited to
262,144 UTF-8 bytes and 65,536 Unicode scalars. Valid UTF-8 beyond either bound
is rejected as `unsupported_content` before a review can be committed.
Import Review also lists every unconsumed top-level `data` key in deterministic
sorted order. `name` and whichever of `description` or the `personality`
fallback actually supplied the displayed description are excluded. The list is
limited to 128 fields; each field name must be printable, non-empty, and at
most 256 UTF-8 bytes or 128 Unicode scalars. Inputs beyond those limits are
rejected instead of placing attacker-controlled unbounded labels in native UI.

Inspection returns an ID and review DTO. Recognized, signature-checked CHARX
assets are streamed to flat temporary files and hashed without loading whole
assets into memory. Commit verifies the snapshot and every staged asset while
placing them in source and asset content-addressed stores, commits SQLite, and
clears the import journal. Discard and successful commit remove all staging
files; startup recovery removes abandoned staging and unreferenced interrupted
CAS writes.

For CHARX, `representative_image` identifies the first signature-valid image in
validated archive order, which is the same deterministic candidate used for
the committed character avatar. It contains only a normalized archive logical
asset identifier, media type, and byte count. It never contains a host path,
staging path, or raw image bytes. Plain JSON cards return no representative
image.
