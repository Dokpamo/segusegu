# Import pipeline

```text
OS picker -> app-owned staging -> inspect -> review -> approve -> commit
```

The native application owns the picker, bounded stream copy, progress,
cancellation, and partial-file cleanup. Rust then verifies the file signature,
format, archive paths, entry count, individual and total size, compression
ratio, normalized collisions, symbolic links, metadata, and asset signatures.

Default hard limits are:

| Limit | Value |
|---|---:|
| Source file | 128 MiB |
| Archive entries | 2,048 |
| One entry | 64 MiB |
| Total uncompressed | 512 MiB |
| Compression ratio | 100:1 |
| Character metadata | 4 MiB |

Inspection returns an ID and review DTO. Commit recomputes SHA-256 from the same
staging path. A mismatch aborts the operation. Storage journals the operation,
moves an immutable source into its content-addressed location, commits SQLite,
and clears the journal.
