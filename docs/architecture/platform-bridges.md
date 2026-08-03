# Platform bridges

## Mainline boundary

The product frontend reaches Rust and operating-system services through a
small, typed Tauri 2 boundary:

```text
Svelte feature
  -> typed IPC client
  -> named Tauri command
  -> shell-api input validation
  -> lorepia-core operation
     or scoped lorepia-platform operation
  -> bounded UI DTO or redacted error
```

The frontend does not invoke arbitrary Rust symbols, platform APIs, SQLite,
provider networking, or filesystem operations. Tauri capabilities identify
each permitted command or plugin operation explicitly; wildcard capabilities
and generic shell/filesystem/network access are not part of a release build.

`shell-api` may:

- convert the current Core contract to a bounded UI projection;
- reject malformed, oversized, stale, or mismatched input;
- replace internal paths with opaque identifiers;
- expose credential availability without credential contents;
- redact errors; and
- transport and reconcile events.

It must not add domain behavior, silently change concurrency semantics, or
become a second persistence layer.

The Tauri application adapter in `apps/lorepia/src-tauri` calls `shell-api` and
the first-party platform plugin as sibling dependencies. It coordinates the
minimum picker or credential operation with the matching Core use case. The
frontend never calls the Rust-only plugin directly.

## Core contract during migration

The frozen baseline contract is:

| Surface | Version |
|---|---:|
| Rust Core API | 8 |
| UniFFI binding API | 8 |
| C ABI | 7 |
| Chat event | 4 |

Initial Tauri commands preserve this behavior:

- character, conversation, branch, and message listings use the existing
  Core-owned `Vec` result;
- send, edit, regenerate, and removal use `expected_head`;
- generation, conversation, branch, assistant-message, and message identifiers
  retain their current representation and meaning;
- event version 4 and its real variants remain the stream source; and
- Core errors are mapped and redacted but are not reclassified into false
  success.

Cursor pagination, `expectedRevision`, or a new Core event requires independent
Core evidence, versioning, and tests. It is not introduced as an incidental UI
adapter choice.

The method-level Core, UniFFI, C ABI, and proposed Tauri mapping is recorded in
[the contract matrix](../migrations/core-tauri-contract-matrix.md).

## Ordered generation stream

Command/response operations use normal Tauri commands. Chat generation uses an
ordered Tauri Channel rather than a global string event bus.

Every delivered item retains:

- `event_version`;
- `generation_id`;
- `conversation_id`;
- optional `branch_id`;
- optional `assistant_message_id`;
- monotonic `sequence`; and
- the version 4 variant topology with a UI-safe payload projection.

The projection preserves event meaning while removing fields the frontend does
not need or must not receive, including provider-raw usage summaries.

The adapter and frontend reject or reconcile an unsupported event version,
wrong identity, duplicate or decreasing sequence, stale lifecycle epoch,
detached view delivery, or delta after a terminal event.

Although the Core wire schema keeps branch and assistant identifiers nullable,
each launch-time Tauri stream requires both. Its first valid event binds a
non-null assistant message ID and every later event must retain it.

Same-process generation reattachment is deliberately unavailable in the
production Tauri path. The registered `subscribe_generation` command has no
application state and returns the stable, nonrecoverable
`generation_reattachment_unavailable` error before registry admission or any
Shell/Core call. The frontend does not invoke that command while restoring or
reconciling persisted state. If a persisted generation is still pending, it
shows a localized blocking alert, retains the generation ID for explicit
cancellation, and keeps new send, edit, and regenerate starts disabled.

Each forwarding receiver has a canonical UUID stream ID in a bounded
32-registration backend registry. Replacing a view, reconciling, destroying the
controller, or explicitly disposing that ID stops only the matching bridge
task. A disposal signal does not release the bounded slot until that task
actually exits and drops its registration. It does not cancel the Core
generation; explicit cancellation uses the Core generation identifier.
Broadcast lag, dropped bridge delivery, process restart, and
background/foreground transitions trigger persisted-state reconciliation. A
still-pending result enters the fail-closed state above rather than creating a
fresh receiver.

The current Core API still cannot atomically validate a live
generation/conversation/branch route while returning status, a sequence
watermark, and an already-established receiver. Keeping reattachment disabled
prevents the persisted-read/subscription terminal gap and invalid-subscription
capacity exhaustion from being reachable through production Tauri. Re-enabling
the feature requires that Core-owned atomic contract or a durable outbox with
equivalent no-gap semantics, plus fail-before-admission tests for unknown,
terminal, and wrong-route generations.

No API key, authorization header, raw cURL credential, secret reference,
private prompt body, or unrestricted path is placed in an event or error.

## Native platform services

### Android

The Kotlin side of `lorepia-platform` owns:

- a native picker and the permission lifetime;
- bounded transport copying;
- Android lifecycle and back behavior;
- notification and deep-link integration; and
- the existing Android Keystore credential format.

Release continuity uses application ID `dev.lorepia.app`, Core root
`context.filesDir/lorepia-data`, key alias
`dev.lorepia.provider-credentials.v1`, and ciphertext under
`context.noBackupFilesDir/provider-credentials`. JavaScript receives an opaque
ticket from a selection and an availability state from a credential operation.
Character import uses `ACTION_OPEN_DOCUMENT` and a bounded private copy. The
separate generated WebView camera chooser uses a non-exported `FileProvider`
whose grant root is restricted to the app-owned external-files `Pictures/`
directory; no general external, cache, files, or root path is allowed.

### iOS and macOS

The iOS Swift and macOS Rust implementations of `lorepia-platform` own:

- security-scoped picker access and bounded transport copying;
- foreground/background and scene lifecycle;
- native menu, notification, and deep-link integration; and
- the established Keychain queries.

Release continuity uses bundle IDs `dev.lorepia.ios` and `dev.lorepia.mac`,
Application Support plus `LorePia` as the Core root, Keychain service
`dev.lorepia.provider-credentials`, provider profile ID as account, Data
Protection Keychain, and
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The macOS legacy Keychain
migration remains part of continuity behavior.

The iOS Swift backend reads the Keychain accessibility attribute, verifies the
exact required value after an update, and restores the prior value and
attribute on an in-process failure. The macOS Rust backend now requests and
decodes the returned accessibility attribute, hardens a nonconforming record,
verifies the exact value and `WhenUnlockedThisDeviceOnly` policy, and restores
the exact prior record after a reported failure. Existing protected records use
`SecItemUpdate`; `SecItemAdd` is used only after a not-found result, so
replacement no longer pre-deletes the current record.

Those source guarantees are not release evidence. The current 23-test Rust
plugin suite passes on the macOS host, but real system-Keychain behavior,
targeted mutation/verification interruption cases, signed access-group
continuity, and old-native-to-Tauri update still require recorded proof.

### Windows

The Windows platform layer owns:

- the native picker and bounded transport copy;
- activation, window, shutdown, notification, deep-link, and menu behavior;
- the production installer identity that must be deliberately established,
  documented, and then held stable for Tauri; and
- the existing PasswordVault convention.

The baseline is an unpackaged WinUI application and has no package identity or
upgrade code to inherit. Its Core root is `%LOCALAPPDATA%\\LorePia`.
PasswordVault uses resource `LorePia.ProviderCredential` and the connection ID
as user name. Vault failure is not collapsed into a missing-credential result.

## File import bridge

The picker never sends the selected absolute path to Svelte:

```text
OS picker
  -> native bounded copy into app-owned transport staging
  -> opaque import ticket
  -> Rust inspection snapshot
  -> safe metadata review in Svelte
  -> explicit Rust commit or discard
  -> transport cleanup
```

Archive size and compression limits, traversal and absolute-path rejection,
symlink rejection, normalized collision rejection, source and asset hash
verification, immutable source storage, and pending-import recovery remain
Core policy. The frontend cannot override or reproduce those gates.

## Credential transactions

A platform plugin performs plaintext credential access only for the duration of
an approved native/Rust operation. Its Tauri-facing result is limited to
available, missing, or a redacted failure.

Create, replacement, delete, discovery, and provider-connection mutations
currently retain the native implementation's in-process compensation
semantics. In particular:

- a failed credential write does not commit Core metadata that assumes success;
- a failed Core mutation compensates a newly written credential when the
  existing operation contract requires it;
- a compensation failure is returned as a failure, not success;
- selection changes cannot retarget an in-flight credential draft;
- target-generation credentials carry the Rust-selected connection identity
  across the native vault await, and Core compares that identity and its
  `credential_ref` with the same validated target snapshot before provider
  construction, chat mutation, or generation registration; and
- Android and iOS schedule provider-controlled import staging separately from
  credential operations so blocked file-provider I/O cannot starve Keystore or
  Keychain access.

This is not a crash-safe transaction. A process exit between the initial
OS-vault write and Core commit is not durably bracketed. Discovery's existing
`Compensating` state models post-failure cleanup, including
`RemoveCredentialSlot`; it must not be reused as a pre-install write journal.
Before production cutover or native-source removal, Core/storage needs a
separate durable credential-install intent/outcome state machine, startup
reconciliation, and crash/failure-injection tests.

That shared state machine does not by itself prove the macOS Keychain record
contract. The macOS source now verifies
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` from returned attributes and
updates an existing item without pre-deleting it. Production and
native-source-removal still require real system-Keychain and signed-continuity
tests, plus targeted failure or interruption evidence around Keychain
mutation, verification, restoration, and the matching Core commit. The current
23-test macOS-host Rust suite is source-level evidence only.

Continuity tests seed only synthetic values through the frozen native harness.
No test uses an actual API key or exposes a seeded value to JavaScript.

## Existing native bridges

UniFFI and the C ABI remain checked-in migration inputs until the Tauri
boundary has equivalent contract coverage and nothing references them.

`lorepia-uniffi` continues to export version 8 records, errors, and a Core-owning
object to the retained Kotlin and Swift clients. Generated Kotlin and Swift
sources remain generated artifacts: public binding changes regenerate both
trees and pass drift checks. Native libraries and XCFrameworks are not
committed.

`bindings/c-api/include/lorepia.h` remains C ABI version 7 for the retained
Windows client. It uses an opaque Core handle, status codes and out parameters,
UTF-8 JSON for larger DTOs, and Rust-owned buffers released only by
`lorepia_buffer_free`.

Provider-discovery snapshot schema version 3 continues to expose its durable
resume boundary and exact persisted connection options. No bridge infers the
next action from aggregate state, changes network mode on resume, or transports
raw assistant tool payloads.

Removal order is deliberate:

1. release and upgrade evidence passes at the Tauri boundary;
2. superseded native UI source is removed in a dedicated commit;
3. retained binding contract tests are replaced with equivalent Tauri tests;
4. only then may UniFFI or the C ABI be removed in a separate cleanup commit.

The complete frozen source remains at
`https://github.com/Dokpamo/lorepia-native-reference`, tag
`native-baseline-before-tauri-2026-08-02`, commit
`66e398fa6256f17b04c82569e6764a9e5332265c`.
