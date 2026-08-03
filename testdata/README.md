# Synthetic test data

Every file in this directory is project-owned and contains no user content.
Regenerate the archives, cards, and packages with:

```bash
cargo xtask testdata regenerate
```

- `cards/` and `packages/` contain minimal accepted examples, including a
  project-owned one-pixel avatar used to verify representative-image metadata,
  deterministic avatar selection, and asset CAS persistence.
- `archives/` contains deliberately hostile or inconsistent ZIP inputs used to
  exercise the import trust boundary.
- `tauri-upgrade/platform-contract.json` is a hand-authored declarative
  continuity contract. The regeneration command does not create or
  semantically validate it.

Do not replace these files with downloaded character cards, private chats,
credentials, or production databases.
