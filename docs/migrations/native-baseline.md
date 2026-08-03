# Frozen native baseline

## Purpose

The native baseline is the complete behavioral, build, upgrade, and technical
rollback reference captured immediately before Tauri 2 became Lorepia's
mainline client. It is not a second product repository and receives no new
product features.

## Immutable record

| Field | Value |
|---|---|
| Source repository | `https://github.com/Dokpamo/segusegu` |
| Frozen reference repository | `https://github.com/Dokpamo/lorepia-native-reference` |
| Baseline tag | `native-baseline-before-tauri-2026-08-02` |
| Annotated tag message | `Frozen native Lorepia baseline before adopting Tauri 2 as the primary client.` |
| Annotated tag object | `9a4a3d5ee08c3457fed9842ccf4184272805e0d0` |
| Baseline commit | `66e398fa6256f17b04c82569e6764a9e5332265c` |
| Tauri migration branch | `codex/tauri-mainline-migration` |
| Migration start date | 2026-08-02 |

The tag and commit are immutable inputs to every parity, upgrade, and rollback
fixture. Do not replace them with a moving branch name.

## Mirror verification

The source repository was mirrored as a complete Git repository rather than as
an extracted `apps` directory. Verification on 2026-08-02 established:

- source `main` and frozen-reference `main` both peel to
  `66e398fa6256f17b04c82569e6764a9e5332265c`;
- the annotated baseline tag object is
  `9a4a3d5ee08c3457fed9842ccf4184272805e0d0` in the mirror and peels to that
  same commit;
- `main`,
  `dependabot/github_actions/microsoft/setup-msbuild-3`, and
  `dependabot/gradle/apps/android/kotlin-2.4.10` are present;
- the Rust Core, Android, Apple, Windows, UniFFI, C ABI, scripts, CI, testdata,
  and documentation trees are present;
- the private frozen-reference repository can be cloned into a fresh path;
- native build instructions remain in the mirrored tree;
- `cargo fmt --all --check` passes in the fresh clone; and
- `cargo test --workspace --all-features --locked` passes in the fresh clone.

The frozen-reference repository remains private. Mirror completion does not
authorize visibility changes, history rewriting, ref deletion, or feature
development there.

## Native identity snapshot

These values come from the project files at the fixed baseline commit. Release
configuration must preserve them where an in-place update depends on identity.
Development Tauri builds use distinct identities so they can coexist with the
native baseline.

| Platform | Baseline product identity | Baseline version |
|---|---|---|
| Android | application ID and namespace `dev.lorepia.app` | `versionName` `0.1.0`, `versionCode` `1` |
| iOS | bundle ID `dev.lorepia.ios` | `MARKETING_VERSION` `0.1.0`, `CURRENT_PROJECT_VERSION` `1` |
| macOS | bundle ID `dev.lorepia.mac` | `MARKETING_VERSION` `0.1.0`, `CURRENT_PROJECT_VERSION` `1` |
| Windows | unpackaged WinUI (`WindowsPackageType=None`); no package identity or installer upgrade code is defined in the baseline project | assembly version `1.0.0.0`; no package or installer sequence |

The Windows absence is part of the baseline contract. A production Tauri
installer identity must be deliberately defined and then held stable; it must
not be documented as inherited from a nonexistent package identity.

## Data-root snapshot

The Tauri release configuration must open the existing Core root rather than a
framework-default app-data directory.

| Platform | Baseline Core root | Native transport/staging |
|---|---|---|
| Android | `context.filesDir/lorepia-data` | `context.cacheDir/import-staging` |
| iOS | user-domain Application Support plus `LorePia`, within the app container | Core-root `native-staging` |
| macOS | user-domain Application Support plus `LorePia` | Core-root `native-staging` |
| Windows | `%LOCALAPPDATA%\\LorePia` | `%LOCALAPPDATA%\\LorePia\\transport-staging` |

Inside every platform Core root, storage opens:

- `db/lorepia.sqlite3` with SQLite WAL journaling, foreign keys enabled, and
  `synchronous=FULL`;
- immutable sources under `sources/sha256`;
- content-addressed assets under `assets/sha256`;
- `cache/thumbnails` and `cache/extracted`;
- Core-owned `staging` and `recovery` directories; and
- the exclusive `.lorepia-owner.lock`.

The baseline schema version is `11`. SQLite may create
`db/lorepia.sqlite3-wal` and `db/lorepia.sqlite3-shm`; an update or rollback
must handle them as SQLite state rather than copying only the main database
file. Core removes abandoned files from its own `staging` directory on open.

Android explicitly sets `android:allowBackup="false"` and keeps credential
ciphertext under the no-backup root. The baseline Apple Core-root code does not
add an application-level backup-exclusion or file-protection attribute beyond
the app container and OS defaults; the macOS app is sandboxed and permits
user-selected read-only files. Windows uses the user's local application-data
root. A release test must verify these effective protections on the signed
Tauri package instead of assuming framework defaults preserve them.

A Tauri update does not silently copy the Core root elsewhere. If a future
platform constraint requires movement, it needs a separate crash-safe
migration with checksums, atomic cutover, old/new round-trip fixtures, and
rollback tests.

## Credential snapshot

### Android

- Store: Android Keystore plus ciphertext in
  `context.noBackupFilesDir/provider-credentials`.
- Key alias: `dev.lorepia.provider-credentials.v1`.
- Cipher: `AES/GCM/NoPadding` with a 128-bit authentication tag.
- Record name:
  `SHA-256(credential reference as UTF-8).credential`.
- Associated data: the same credential reference. The current native caller
  uses the provider profile identifier as that reference.
- Record format: big-endian version `1`, IV length, IV bytes, ciphertext length,
  and ciphertext bytes, written through `AtomicFile`.

### iOS and macOS

- Store: generic-password Keychain item.
- Service: `dev.lorepia.provider-credentials`.
- Account: provider profile identifier.
- Production query: Data Protection Keychain enabled.
- Accessibility for new and updated values:
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- macOS additionally reads the legacy non-Data-Protection query and migrates a
  valid value to the protected item before deleting the legacy item.

### Windows

- Store: `Windows.Security.Credentials.PasswordVault`.
- Resource: `LorePia.ProviderCredential`.
- User name: connection identifier passed to the credential store.
- A replacement write preserves the previous value and attempts compensation
  if the new vault write fails.

The Tauri platform plugin must preserve each of these identifiers and record
semantics. JavaScript receives only available, missing, or redacted failure
state. Continuity tests use synthetic credentials and platform-native seed
harnesses, never actual API keys.

## Core contract snapshot

At the baseline commit:

- Core API version is `8`;
- UniFFI binding API version is `8`;
- C ABI version is `7`;
- `ChatEvent` version is `4`;
- `list_characters`, `list_conversations`,
  `list_conversation_branches`, and message-list methods return `Vec` results;
- branch-targeted send, edit, regenerate, and removal operations use
  branch-head identity (`expected_head`) rather than a synthetic
  `expectedRevision`; active-branch send resolves the current head internally;
  and
- the persisted identifiers for generations, conversations, branches, and
  messages are part of the behavior to preserve.

`ChatEvent` version 4 contains these variants:

- `generation_started`;
- `reasoning_delta`;
- `text_delta`;
- `tool_call_started`;
- `tool_call_arguments_delta`;
- `tool_call_completed`;
- `usage_updated`;
- `message_committed`;
- `generation_cancelled`;
- `generation_failed`; and
- `generation_finished`.

The migration maps these facts rather than presenting proposed pagination,
revision, or event concepts as existing Core behavior. See the
[Core-to-Tauri contract matrix](core-tauri-contract-matrix.md).

## Technical rollback

The Accepted architecture remains Tauri even if a release gate fails; the team
fixes the defect or records a new decision. The frozen baseline still provides
a technical rollback path:

1. clone the frozen-reference repository and verify the annotated tag;
2. check out the tag's peeled commit, never a moving branch;
3. build with the preserved native instructions and compatible signing
   lineage;
4. exercise a synthetic database and credential fixture through the intended
   update and rollback sequence;
5. verify schema version, assets, conversations, routes, presets, credential
   availability, and database integrity after rollback; and
6. keep Tauri-only schema changes out of production until that round trip is
   proven.

The frozen Android/iOS/macOS source carries build value `1`; it is not
automatically installable over a released Tauri build `2` on channels that
enforce monotonic build numbers. A compatible in-place rollback may require
repackaging the frozen code with the same accepted product/signing identity and
a rollback build number greater than `2`. Restoring an exact disposable-target
snapshot remains useful disaster-recovery evidence, but it is not proof that
users can install an older application package in place.

Rollback is an explicit signed release operation. It is not an instruction to
overwrite a user's data directory, rewrite Git history, or resume feature work
in the frozen repository.
