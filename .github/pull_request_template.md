## What changed

Describe the behavior and affected platforms.

## Why

Explain the user or developer impact and, for fixes, the root cause.

## Validation

List commands actually executed and their results. Separate checks that could
not run on the current host.

## Tauri migration

- Native baseline tag/SHA:
- Core-to-Tauri contract rows changed:
- Data-root or credential continuity impact:
- Frontend, Tauri, Android, iOS, macOS, and Windows checks:
- Checks deferred to hosted CI or blocked by signing/host access:
- Native reference code removed: no / yes, with passed removal gate evidence

## Safety

- [ ] No credential, private conversation, user database, or user package is included.
- [ ] Generated bindings were regenerated when the public core API changed.
- [ ] JavaScript receives no raw credential or unrestricted absolute path.
- [ ] Tauri capabilities allow only commands implemented and tested in this change.
- [ ] New Cargo and npm artifacts have an exact-version dependency intake record.
- [ ] Documentation describes current behavior only.
- [ ] No license file or project-authored license header was added.
