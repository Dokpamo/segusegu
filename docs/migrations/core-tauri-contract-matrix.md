# Core–Tauri Contract Matrix

Status: migration baseline

Audited commit: `66e398fa6256f17b04c82569e6764a9e5332265c`

Audit date: 2026-08-02

This document records the public Core behavior that the Tauri adapter must
preserve. The Core, UniFFI, and C ABI columns describe the audited native
baseline commit. The Tauri column and Tauri source links describe the mutable
migration worktree and do not by themselves claim a passing build. This is not
a proposal to redesign Core. Rust `Core` is the semantic source of truth.
UniFFI and the C ABI are evidence of the projections used by the frozen native
clients, but the Tauri application calls `lorepia-core` through `shell-api`, not
through either FFI layer.

The version baseline is:

- `CORE_API_VERSION = 8`
  ([`crates/core/src/lib.rs:83`](../../crates/core/src/lib.rs#L83));
- UniFFI `BINDING_API_VERSION = 8`
  ([`bindings/uniffi/src/lib.rs:61`](../../bindings/uniffi/src/lib.rs#L61));
- C `ABI_VERSION = 7`
  ([`bindings/c-api/src/lib.rs:51`](../../bindings/c-api/src/lib.rs#L51));
- `CHAT_EVENT_VERSION = 4`
  ([`crates/chat/src/events.rs:8`](../../crates/chat/src/events.rs#L8)).

## Reading the matrix

- **Standard Core error** means `CoreError { code, message, recoverable,
  operation_id }`. Stable codes are defined in
  [`crates/domain/src/error.rs:5`](../../crates/domain/src/error.rs#L5).
  UniFFI preserves those four fields in `FfiError`; the C ABI returns a numeric
  status and the same structured fields through `last_error_json`. `shell-api`
  must expose a bounded, serializable equivalent and must not replace these
  semantics with an unstructured string.
- **Direct mapping** means semantic mapping, not unrestricted serialization of
  a Core domain object. The frontend receives explicit UI-safe DTOs.
- **Existing test evidence** names tests present at the audited commit. The
  references do not claim that those tests were executed as part of this
  documentation-only change.
- `expected_revision` remains valid for the provider-discovery state machine.
  It is not the conversation concurrency mechanism. Chat, branch, and message
  mutations use `expected_head`.

## Contract matrix

| Product feature | Current Core | Current UniFFI | Current C ABI | Input type | Output type | Error semantics | Credential boundary | Cancellation semantics | Restart semantics | Current/required Tauri mapping | Channel | Direct mapping | Gap | Core change required | Test evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Bootstrap and version | `Core::open(CoreConfig)`; `core_version`; constants ([`app.rs:447`](../../crates/core/src/app.rs#L447), [`lib.rs:83`](../../crates/core/src/lib.rs#L83)) | `LorepiaCore::open(FfiCoreConfig)`; `core_version`; `version_info` ([`lib.rs:1688`](../../bindings/uniffi/src/lib.rs#L1688)) | `lorepia_core_create`; `lorepia_core_version`; `lorepia_abi_version` ([`lib.rs:1319`](../../bindings/c-api/src/lib.rs#L1319)) | Core: trusted absolute `data_root`; bindings: string/JSON path | Live Core handle plus version and health projection | Open may return any standard storage/configuration error; C converts a caught ABI-boundary panic into an internal error | No credential input | Dropping the last Core cancels active generation work before runtime shutdown | Opening Storage applies migrations and conservative recovery before Core is exposed | `bootstrap() -> BootstrapDto`, containing Core/Chat versions and health ([`commands.rs:27`](../../apps/lorepia/src-tauri/src/commands.rs#L27), [`dto.rs:12`](../../crates/shell-api/src/dto.rs#L12)) | No | No: data-root resolution and Core ownership require shell coordination | The frontend must not choose or receive the unrestricted data-root path | No | `opens_core_and_maps_version_health_and_empty_event_batch` ([`bindings/uniffi/src/lib.rs:7072`](../../bindings/uniffi/src/lib.rs#L7072)); owner-lock recovery test ([`database.rs:8535`](../../crates/storage/src/database.rs#L8535)) |
| Health | `Core::health_check` ([`app.rs:476`](../../crates/core/src/app.rs#L476)) | `health_check` ([`lib.rs:1716`](../../bindings/uniffi/src/lib.rs#L1716)) | `lorepia_core_health_check_json` ([`lib.rs:1457`](../../bindings/c-api/src/lib.rs#L1457)) | None | Core version, DB/schema/writability/recovery flags, aggregate active-job count | Standard Core error | None | Reports an aggregate active-job count; it does not cancel work | Reports storage recovery state after open; it does not enumerate restored generations | Current `bootstrap()` returns `HealthDto`; there is no separate Tauri `health_check` command ([`api.rs:117`](../../crates/shell-api/src/api.rs#L117)) | No | Yes, after DTO projection | No independently refreshable health command, per-generation state, or job identifiers | No for initial parity | `opens_core_and_maps_version_health_and_empty_event_batch` ([`bindings/uniffi/src/lib.rs:7072`](../../bindings/uniffi/src/lib.rs#L7072)) |
| Import inspection | `Core::inspect_import(path)` ([`app.rs:506`](../../crates/core/src/app.rs#L506)) | `inspect_import(staged_path: String)` ([`lib.rs:1729`](../../bindings/uniffi/src/lib.rs#L1729)) | `lorepia_core_inspect_import_json(staged_path)` ([`lib.rs:1472`](../../bindings/c-api/src/lib.rs#L1472)) | Core receives a real staged path; binding inputs are path strings | `ImportInspection` or safe inspection DTO with logical image metadata, warnings, blocked reasons, hashes, sizes, and inspection ID | Invalid, unsafe, unsupported, permission, storage, or corruption errors remain structured | No credential. The source path is sensitive filesystem state and is not a frontend output | Not cancellable through the current public contract | The pending inspection map is process-local. An uncommitted inspection is not resumable; startup removes abandoned staging files | `inspect_import(import_ticket)` after platform picker and bounded app-owned transport copy | No | No: shell coordination is required | The current Core entry point accepts a path, while JS must receive only an opaque import ticket | No | Import snapshot/restart coverage ([`crates/core/tests/import_vertical_slice.rs:8`](../../crates/core/tests/import_vertical_slice.rs#L8)); abandoned staging cleanup ([`app.rs:7210`](../../crates/core/src/app.rs#L7210)) |
| Import commit and discard | `commit_import(InspectionId)`; `discard_import(InspectionId)` ([`app.rs:536`](../../crates/core/src/app.rs#L536)) | `commit_import`; `discard_import` ([`lib.rs:1736`](../../bindings/uniffi/src/lib.rs#L1736)) | `lorepia_core_commit_import_json`; `lorepia_core_discard_import` ([`lib.rs:1494`](../../bindings/c-api/src/lib.rs#L1494)) | Opaque inspection ID | Commit returns `Character`; discard returns unit | Not-found when no live pending inspection exists; blocked inspections fail closed; storage errors preserve Core fields | None | No public cancellation once commit begins; discard is the explicit pre-commit cancellation path | A committed character persists. A pre-restart inspection ID is invalid after restart and must be reinspected | `commit_import(inspection_id)`; `discard_import(inspection_id)` | No | Yes, after DTO projection | Frontend transport cleanup must also run on terminal success/failure | No | Commit/restart and discard tests ([`crates/core/tests/import_vertical_slice.rs:8`](../../crates/core/tests/import_vertical_slice.rs#L8), [`crates/core/tests/import_vertical_slice.rs:39`](../../crates/core/tests/import_vertical_slice.rs#L39)) |
| Character library | `list_characters() -> Vec<Character>`; `get_character` ([`app.rs:614`](../../crates/core/src/app.rs#L614)) | `list_characters() -> Vec<FfiCharacter>`; `get_character` ([`lib.rs:1749`](../../bindings/uniffi/src/lib.rs#L1749)) | `list_characters_json`; `get_character_json` ([`lib.rs:1535`](../../bindings/c-api/src/lib.rs#L1535)) | None or character ID | Whole `Vec` or one character; there is no page/cursor envelope | Standard Core error; unknown ID is not-found | None | Not applicable | Persisted and available after reopen | `list_characters()`; `get_character(character_id)` | No | Yes, after DTO projection | No cursor pagination exists and none is required for initial parity | No | 1,000-character performance scenario ([`crates/core/tests/performance_scenarios.rs:207`](../../crates/core/tests/performance_scenarios.rs#L207)); import/restart test ([`app.rs:7177`](../../crates/core/src/app.rs#L7177)) |
| Conversation creation and listing | `open_conversation`; `create_conversation`; `list_conversations() -> Vec`; `list_conversations_for_character() -> Vec`; `get_conversation` ([`app.rs:622`](../../crates/core/src/app.rs#L622)) | All five methods ([`lib.rs:1763`](../../bindings/uniffi/src/lib.rs#L1763)) | Only `open_conversation_json` and unfiltered `list_conversations_json` ([`lib.rs:1572`](../../bindings/c-api/src/lib.rs#L1572)) | Character ID; explicit create also accepts bounded title and `chat`/`story` mode | Conversation or whole `Vec<Conversation>` | Standard validation/not-found/storage errors | None | Not applicable | Conversations persist | `open_conversation(character_id)`; `create_conversation(input)`; `list_conversations()`; `list_conversations_for_character(character_id)`; `get_conversation(id)` | No | Yes, after DTO projection | C ABI is not complete evidence for this feature; there is no cursor pagination | No | Multiple-room contract ([`app.rs:7493`](../../crates/core/src/app.rs#L7493)); UniFFI room coverage ([`bindings/uniffi/src/lib.rs:7154`](../../bindings/uniffi/src/lib.rs#L7154)) |
| Conversation state and branches | `get_conversation_state`; `list_conversation_branches() -> Vec`; `create_conversation_branch`; `select_conversation_branch`; `set_conversation_mode` ([`app.rs:665`](../../crates/core/src/app.rs#L665)) | All methods ([`lib.rs:1807`](../../bindings/uniffi/src/lib.rs#L1807)) | No corresponding public C ABI methods | Conversation ID, branch ID, optional source message ID/title, or mode | State, branch, or whole `Vec<ConversationBranch>` | Standard validation/not-found/storage errors | None | Branch selection/mode operations do not cancel an active generation | Active branch, branch graph, and mode persist | `get_conversation_state(id)`; `list_conversation_branches(id)`; `create_conversation_branch(input)`; `select_conversation_branch(input)`; `set_conversation_mode(input)` | No | Yes, after DTO projection | C ABI coverage is absent; timestamps are not revisions | No | Branch lineage/stale-head test ([`app.rs:7622`](../../crates/core/src/app.rs#L7622)); UniFFI room/branch test ([`bindings/uniffi/src/lib.rs:7154`](../../bindings/uniffi/src/lib.rs#L7154)) |
| Message history and reconciliation | `list_branch_messages(branch_id) -> Vec<Message>`; `list_messages(conversation_id) -> Vec<Message>` for the active branch ([`app.rs:723`](../../crates/core/src/app.rs#L723)) | Both methods ([`lib.rs:1870`](../../bindings/uniffi/src/lib.rs#L1870)) | Only active-branch `list_messages_json` ([`lib.rs:1608`](../../bindings/c-api/src/lib.rs#L1608)) | Branch ID or conversation ID | Whole ordered lineage `Vec<Message>` with message status and generation ID | Standard not-found/storage/corruption errors | No secret material; private conversation content is returned only to the trusted product UI | Read-only | This is the authoritative content/status reconciliation surface after lag or restart | `list_branch_messages(branch_id)`; `list_messages(conversation_id)` | No | Yes, after DTO projection | It cannot restore persisted usage details because no public `get_generation` projection exists | No for message parity; yes if persisted usage recovery becomes a requirement | 100,000-message metadata scenario ([`crates/core/tests/performance_scenarios.rs:237`](../../crates/core/tests/performance_scenarios.rs#L237)); branch send projection ([`bindings/uniffi/src/lib.rs:8107`](../../bindings/uniffi/src/lib.rs#L8107)) |
| Send message on selected branch | `send_message`; `send_message_with_target` resolve the active branch/head internally ([`app.rs:737`](../../crates/core/src/app.rs#L737)) | Both methods ([`lib.rs:1884`](../../bindings/uniffi/src/lib.rs#L1884)) | `send_message_json`; `send_message_with_target_json` ([`lib.rs:1634`](../../bindings/c-api/src/lib.rs#L1634)) | Conversation ID, bounded text, legacy profile or `GenerationTarget`, transient optional credential | `GenerationId` | Standard errors. The active head is read immediately before the transactional append | Core accepts plaintext only for the duration of the call/task and never persists it. JS must not supply it | Returned generation ID is cancellable only while registered in the live Core | Same-process generation can continue while a view detaches. Process restart does not resume it | `send_message(input)` using shell-resolved platform credential | No; events use the shared chat Channel | No: credential orchestration and event subscription ordering are required | The active-branch convenience call does not accept a UI snapshot `expected_head` | No for current convenience semantics; explicit branch send should be used when stale-view detection is required | Chat persistence/no-secret test ([`crates/core/tests/chat_vertical_slice.rs:219`](../../crates/core/tests/chat_vertical_slice.rs#L219)) |
| Send message to explicit branch | `send_message_to_branch`; `send_message_to_branch_with_target`, both with `expected_head: Option<MessageId>` ([`app.rs:800`](../../crates/core/src/app.rs#L800)) | Both methods preserve `expected_head` ([`lib.rs:1921`](../../bindings/uniffi/src/lib.rs#L1921)) | Only target-based branch send, also with `expected_head` ([`lib.rs:1718`](../../bindings/c-api/src/lib.rs#L1718)) | Conversation ID, branch ID, nullable expected head, mode, text, target/profile, transient credential | `GenerationId` | Head mismatch returns recoverable `invalid_input`: “conversation branch head changed; refresh before retrying” ([`database.rs:6638`](../../crates/storage/src/database.rs#L6638)) | JS supplies no credential; shell resolves it and passes it transiently | Explicit `cancel_generation` after successful launch | On restart the running record is cancelled; no automatic resend | `send_message_to_branch(input)` | No; events use the shared chat Channel | No: credential orchestration; otherwise semantic mapping is direct | Do not substitute `expectedRevision`; null means the caller expects an empty branch | No | Transactional expected-head check ([`database.rs:988`](../../crates/storage/src/database.rs#L988)); stale-head test ([`app.rs:7622`](../../crates/core/src/app.rs#L7622)) |
| Edit user message | `edit_user_message`; `edit_user_message_with_target`, both with `expected_head` ([`app.rs:860`](../../crates/core/src/app.rs#L860)) | Both methods ([`lib.rs:1975`](../../bindings/uniffi/src/lib.rs#L1975)) | Only target-based edit ([`lib.rs:1758`](../../bindings/c-api/src/lib.rs#L1758)) | Conversation/branch/head IDs, target message ID, replacement text, target/profile, transient credential | `MessageActionGeneration { branch, generation_id }` | Stale/wrong-room/wrong-role/pending-head cases remain structured. The source lineage is immutable | JS supplies no credential; shell resolves it | New generation can be cancelled by returned ID | New branch and any terminal message persist; interrupted running generation follows normal restart cancellation | `edit_user_message(input)` | No; events use the shared chat Channel | No: credential orchestration; branch/generation result maps directly | Edit means fork-and-generate, not in-place mutation | No | Immutable action/rewind test ([`app.rs:7765`](../../crates/core/src/app.rs#L7765)); rejection matrix ([`app.rs:7952`](../../crates/core/src/app.rs#L7952)) |
| Regenerate assistant message | `regenerate_assistant_message`; target variant, both with `expected_head` ([`app.rs:922`](../../crates/core/src/app.rs#L922)) | Both methods ([`lib.rs:2027`](../../bindings/uniffi/src/lib.rs#L2027)) | Only target-based regeneration ([`lib.rs:1798`](../../bindings/c-api/src/lib.rs#L1798)) | Conversation/branch/head IDs, assistant message ID, target/profile, transient credential | `MessageActionGeneration` | Same branch snapshot, lineage, role, and active-generation validation as edit | JS supplies no credential; shell resolves it | New generation can be cancelled by returned ID | Same as edit | `regenerate_assistant_message(input)` | No; events use the shared chat Channel | No: credential orchestration; otherwise direct | Regeneration forks a branch; it does not overwrite the assistant row | No | Message-action test ([`bindings/uniffi/src/lib.rs:8180`](../../bindings/uniffi/src/lib.rs#L8180)); copied-text validation ([`app.rs:8180`](../../crates/core/src/app.rs#L8180)) |
| Remove message from branch | `remove_message_from_branch` with `expected_head` ([`app.rs:981`](../../crates/core/src/app.rs#L981)) | `remove_message_from_branch` ([`lib.rs:2074`](../../bindings/uniffi/src/lib.rs#L2074)) | No public C ABI method | Conversation/branch/head IDs and target message ID | Updated `ConversationBranch` | Stale head is recoverable `invalid_input`; pending generation action is rejected | None | Does not implicitly cancel; pending targets/heads are rejected | Logical head rewind persists. Shared message rows and sibling branches remain | `remove_message_from_branch(input)` | No | Yes, after DTO projection | C ABI coverage is absent; removal is logical, not physical deletion | No | Storage branch-snapshot test ([`database.rs:11740`](../../crates/storage/src/database.rs#L11740)); UniFFI action/removal test ([`bindings/uniffi/src/lib.rs:8180`](../../bindings/uniffi/src/lib.rs#L8180)) |
| Cancel generation | `cancel_generation(GenerationId)` addresses the in-memory registry ([`app.rs:996`](../../crates/core/src/app.rs#L996), [`app.rs:349`](../../crates/core/src/app.rs#L349)) | `cancel_generation` ([`lib.rs:2093`](../../bindings/uniffi/src/lib.rs#L2093)) | `lorepia_core_cancel_generation` ([`lib.rs:1834`](../../bindings/c-api/src/lib.rs#L1834)) | Generation ID | Unit; terminal state arrives asynchronously | Unknown/already-removed ID is not-found; a closed cancellation channel returns recoverable cancelled | No credential | Explicit cancellation signals the live task. Partial text is retained only according to `preserve_partial_generations` and whether content exists | After process restart the old generation is no longer cancellable through the registry | `cancel_generation(generation_id)` | No; terminal event uses the shared chat Channel | Yes | Cancel is not an idempotent “ensure cancelled” command | No | Core cancellation test ([`crates/core/tests/chat_vertical_slice.rs:302`](../../crates/core/tests/chat_vertical_slice.rs#L302)); UniFFI ordered cancellation test ([`bindings/uniffi/src/lib.rs:8328`](../../bindings/uniffi/src/lib.rs#L8328)); C ABI cancellation test ([`bindings/c-api/src/lib.rs:7008`](../../bindings/c-api/src/lib.rs#L7008)) |
| Chat event stream | `subscribe_events() -> broadcast::Receiver<ChatEvent>`; broadcast capacity 256 ([`app.rs:1000`](../../crates/core/src/app.rs#L1000), [`app.rs:462`](../../crates/core/src/app.rs#L462)) | One receiver per binding object; `poll_events(1..=256) -> FfiEventBatch` with `dropped_event_count` ([`lib.rs:1638`](../../bindings/uniffi/src/lib.rs#L1638), [`lib.rs:2099`](../../bindings/uniffi/src/lib.rs#L2099)) | One receiver per handle; `poll_events_json(1..=1024)` with `dropped_events` ([`lib.rs:124`](../../bindings/c-api/src/lib.rs#L124), [`lib.rs:1857`](../../bindings/c-api/src/lib.rs#L1857)) | Send, edit, and regenerate carry a per-generation Channel. The registered re-entry command still accepts generation/conversation/branch IDs, a sequence baseline, and a Channel only to return a stable failure | Ordered version-4 events for launch-time streams. Reattachment returns no event and fails with `generation_reattachment_unavailable` | Receiver validation errors are structured. Lag requires persisted refresh. Reattachment failure is stable and nonrecoverable | Events must not contain API keys, auth headers, cURL secrets, credential references, or private prompt bodies | Stream disposal stops only that receiver-to-Channel task, never the Core generation. Generation cancellation remains explicit, including from the blocked persisted-pending UI state | Broadcast has no replay. Production Tauri does not attempt same-process reattachment, and process restart emits no replay event | `send_message`, `edit_user_message`, and `regenerate_assistant_message` each take `on_event: Channel<ChatStreamItem>`. Registered `subscribe_generation` fails without application state and before registry, Shell, or Core access; `dispose_chat_stream` remains separate ([`commands.rs:254`](../../apps/lorepia/src-tauri/src/commands.rs#L254), [`commands.rs:328`](../../apps/lorepia/src-tauri/src/commands.rs#L328)) | Yes for launch-time streams; no reattachment items are delivered | No: launch-time mapping is direct after subscription ordering, but safe reattachment needs Core coordination ([`api.rs:299`](../../crates/shell-api/src/api.rs#L299), [`stream.rs:52`](../../crates/shell-api/src/stream.rs#L52)) | Safe same-process re-entry and persisted usage recovery are unavailable. The fail-closed command prevents a read/subscription terminal gap or arbitrary identifiers from consuming bounded registrations | **Yes before re-enabling reattachment:** add a Core-owned atomic live-generation/route/status/watermark subscription contract or durable outbox with equivalent semantics. A separate read-only generation projection is also needed if persisted usage recovery is required | Adapter routing, lag, assistant identity, sequence, post-terminal, and disposal tests ([`stream.rs:247`](../../crates/shell-api/src/stream.rs#L247)); stable fail-closed error and repeated rejection beyond registry capacity ([`error.rs`](../../apps/lorepia/src-tauri/src/error.rs), [`state.rs`](../../apps/lorepia/src-tauri/src/state.rs)); launch-time Tauri Channel transport ([`commands.rs:254`](../../apps/lorepia/src-tauri/src/commands.rs#L254)); Core/FFI event variants and ordering ([`bindings/uniffi/src/lib.rs:7934`](../../bindings/uniffi/src/lib.rs#L7934), [`bindings/uniffi/src/lib.rs:8328`](../../bindings/uniffi/src/lib.rs#L8328)) |
| Chat event shape | `ChatEvent` plus `ChatEventKind` ([`events.rs:12`](../../crates/chat/src/events.rs#L12)) | Flat `FfiChatEvent` with `kind: String` and nullable payload fields ([`lib.rs:1612`](../../bindings/uniffi/src/lib.rs#L1612)) | Serializes the Core tagged enum in JSON | Core fields: event/generation/conversation IDs, nullable branch and assistant IDs, sequence, time, variant payload | Exact v4 variants listed below | Unsupported event version is a frontend compatibility/reconciliation condition, not a current Core error | Core generation guards provider output against reflected credentials; adapter still must avoid secret-bearing diagnostics | Terminal variants are cancelled, failed, and finished. `MessageCommitted` can precede a terminal event when an assistant row is retained | No durable event replay | `ChatStreamItem::Event` is delivered only by launch-time send/edit/regenerate Channels; disabled `subscribe_generation` delivers none | Yes for launch-time streams | Yes, after explicit discriminated-union projection | UniFFI and C wire shapes already differ. Preserve semantic fields/variants, not either byte layout | No | Variant mapping test ([`bindings/uniffi/src/lib.rs:7934`](../../bindings/uniffi/src/lib.rs#L7934)); C v4 event assertion ([`bindings/c-api/src/lib.rs:6644`](../../bindings/c-api/src/lib.rs#L6644)) |
| Chat lag reconciliation | Core exposes `broadcast::error::Lagged`; persisted query surface is conversation state plus branch messages | Converts lag to `dropped_event_count`; comment requires persisted refresh ([`lib.rs:1641`](../../bindings/uniffi/src/lib.rs#L1641)) | Converts lag to `dropped_events`; comment requires persisted refresh ([`lib.rs:1848`](../../bindings/c-api/src/lib.rs#L1848)) | Detected skipped count and current conversation/branch selection | Fresh persisted `ConversationState` and `Vec<Message>` | Lag itself is not failure; failure to reload uses standard Core error | No credential | Must not cancel a generation merely because events were dropped | Persisted reload is also used after view re-entry, but a still-pending generation enters the blocked state instead of reconnecting. Process restart yields persisted cancelled/rewound state | Internal shell reconciliation signal plus `get_conversation_state` and `list_branch_messages`; do not invent a Core `Dropped` event | Channel carries an adapter control envelope, clearly distinguished from `ChatEventKind` | No: adapter behavior | There is no Core `Dropped`, `Reconciled`, or `PendingRestored` variant | No for message/status recovery | Batch drop semantics ([`bindings/uniffi/src/lib.rs:1638`](../../bindings/uniffi/src/lib.rs#L1638), [`bindings/c-api/src/lib.rs:1848`](../../bindings/c-api/src/lib.rs#L1848)) |
| Generation restart recovery | Storage startup recovery, not a public Core generation-resume method ([`database.rs:5925`](../../crates/storage/src/database.rs#L5925)) | Observed through persisted message queries; no resume-generation method | Same; no resume-generation method | Existing DB plus `preserve_partial_generations` setting | Running generations become cancelled; partial assistant is retained as cancelled when preservation is enabled, otherwise removed and branch head rewound | Startup storage errors remain structured and can prevent Core open | No credential is persisted or available to replay a provider request | Core drop signals cancellation and waits at most 750 ms before runtime shutdown ([`app.rs:70`](../../crates/core/src/app.rs#L70), [`app.rs:412`](../../crates/core/src/app.rs#L412)) | No automatic retry or generation resume after process restart | No resume command. Bootstrap then query state/messages | No | Yes: preserve current recovery semantics | “Restore pending generation” means persisted-state recovery only. Production Tauri does not reconnect to a live same-process stream and must never replay the provider request | No | Partial-preserved restart test ([`app.rs:7089`](../../crates/core/src/app.rs#L7089)); partial-discard restart test ([`app.rs:7127`](../../crates/core/src/app.rs#L7127)) |
| Application settings | `get_settings`; `update_settings` ([`app.rs:1004`](../../crates/core/src/app.rs#L1004)) | Both, with update returning a fresh projection ([`lib.rs:3042`](../../bindings/uniffi/src/lib.rs#L3042)) | `get_settings_json`; `update_settings_json` ([`lib.rs:1897`](../../bindings/c-api/src/lib.rs#L1897)) | `AppSettings`: partial-preservation and selected provider/route/preset IDs | Current settings | Selected generation target is validated; standard Core error | No raw credential or credential reference | `preserve_partial_generations` controls terminal/restart partial-message retention, not whether cancellation occurs | Persisted | `get_settings()`; `update_settings(input)` | No | Yes, after DTO projection | Frontend must not infer a provider target from mismatched IDs | No | Persistence across reopen ([`database.rs:11956`](../../crates/storage/src/database.rs#L11956)); generation target selection tests in Core app module |
| Provider templates and connections | `list_provider_template_views() -> Vec`; `create/list/upsert/delete_provider_connection` ([`app.rs:1059`](../../crates/core/src/app.rs#L1059), [`app.rs:1073`](../../crates/core/src/app.rs#L1073)) | Full template/connection surface; connection DTO exposes `credential_slot_ready`, not the ref string ([`lib.rs:405`](../../bindings/uniffi/src/lib.rs#L405), [`lib.rs:2656`](../../bindings/uniffi/src/lib.rs#L2656)) | Full surface, but its output DTO includes the opaque `credential_ref` string ([`lib.rs:1197`](../../bindings/c-api/src/lib.rs#L1197), [`lib.rs:5571`](../../bindings/c-api/src/lib.rs#L5571)) | Secret-free connection draft/DTO plus platform-owned vault operation outside Core | Templates/connections as whole `Vec`s or one connection | Endpoint, network approval, credential scope, and immutable binding validation remain Core-owned | Core persists only `CredentialRef` and `CredentialScope`; for credentialed creation Core derives the ref from exact connection ID ([`app.rs:1171`](../../crates/core/src/app.rs#L1171)). Stored credentials never return to JS; the dedicated create request may carry one transient new value | Not applicable | Connection metadata persists; vault continuity is platform-owned | `list_provider_templates()`; `create_provider_connection(request: { input, credential? })`; `list_provider_connections()`; `upsert_provider_connection(request: { input })`; `delete_provider_connection(request: { connection_id })` | No | No: platform vault and compensation coordination are required | Do not expose the C ABI `credential_ref`. The Tauri backend preserves native-equivalent in-process rollback, but the initial OS-vault write and Core connection commit have no durable pre-install intent/outcome bracket | No for Core metadata; **yes before production removal** for a separate Core/storage credential-install state machine, startup reconciliation, and crash/failure-injection tests. Do not reuse discovery `Compensating` as that journal | Endpoint/ref immutability ([`app.rs:4598`](../../crates/core/src/app.rs#L4598)); UniFFI slot derivation ([`bindings/uniffi/src/lib.rs:5166`](../../bindings/uniffi/src/lib.rs#L5166)); current in-process rollback ([`provider_commands.rs:316`](../../apps/lorepia/src-tauri/src/provider_commands.rs#L316)) |
| Provider credential use | Generation, model sync, and discovery-assistant methods accept a borrowed/transient credential; Core does not own an OS vault | Native caller passes `Option<String>` for each operation; cURL inspection uses a two-minute, take-once in-memory handoff ([`lib.rs:2167`](../../bindings/uniffi/src/lib.rs#L2167)) | Raw credential is carried outside request JSON as a separate pointer/length; cURL inspection returns it in a distinct zeroed-on-free buffer ([`lib.rs:2500`](../../bindings/c-api/src/lib.rs#L2500), [`lib.rs:4001`](../../bindings/c-api/src/lib.rs#L4001)) | Generation, read, and status commands: JS supplies only a connection/target ID. Dedicated create/update commands: JS may supply a transient newly entered secret. Shell/plugin: transient credential bytes/string | Availability/missing/error status to JS; never stored or transient secret bytes | Vault missing and vault failure must remain distinct at the shell error layer; Core provider errors retain stable codes | Platform plugin reads/writes/deletes. Stored secrets never return to JS. A newly entered secret is best-effort cleared after the dedicated ingress and must not enter frontend persistence, events, logs, stores, or error DTOs | Operation-specific cancellation; cancelling must release the captured credential with the provider/task | Secrets are not persisted outside the platform vault, so network work cannot auto-resume after process restart | Internal `resolve_credential_and_*`; public `credential_status`, `set_credential`, `delete_credential` | No | No: security boundary orchestration | Current Core generation and lifecycle methods accept plaintext, so exposing those signatures directly as Tauri commands would violate the architecture; dedicated credential ingress is distinct | No for transient generation/read use; **yes** for crash-safe initial vault install plus connection commit. Platform plugin and shell secret-lifetime work are also required | No-secret persistence ([`crates/core/tests/chat_vertical_slice.rs:219`](../../crates/core/tests/chat_vertical_slice.rs#L219)); reflection rejection ([`crates/core/tests/chat_vertical_slice.rs:351`](../../crates/core/tests/chat_vertical_slice.rs#L351)); cURL handoff test ([`bindings/uniffi/src/lib.rs:6811`](../../bindings/uniffi/src/lib.rs#L6811)) |
| Model routes, capability controls, and presets | List/upsert/delete routes; list/effective/user-override capability methods; list/upsert/delete/validate/render/preview presets ([`app.rs:1270`](../../crates/core/src/app.rs#L1270), [`app.rs:1431`](../../crates/core/src/app.rs#L1431), [`app.rs:1611`](../../crates/core/src/app.rs#L1611)) | Corresponding typed DTO methods ([`lib.rs:2696`](../../bindings/uniffi/src/lib.rs#L2696), [`lib.rs:2873`](../../bindings/uniffi/src/lib.rs#L2873), [`lib.rs:2935`](../../bindings/uniffi/src/lib.rs#L2935)) | Corresponding versioned JSON methods ([`lib.rs:2061`](../../bindings/c-api/src/lib.rs#L2061), [`lib.rs:2134`](../../bindings/c-api/src/lib.rs#L2134), [`lib.rs:3681`](../../bindings/c-api/src/lib.rs#L3681)) | Connection/route/preset IDs and typed secret-free records | Whole `Vec`s, effective capability, rendered controls, or redacted request preview | Core validates provenance, immutable route identity, parameter constraints, and target consistency | No raw credentials. Request preview is explicitly credential-free | Not applicable | Persisted | Matching CRUD/validation command names under `providers` | No | Yes, after explicit DTO projection | No UI-side reconstruction of provider dialect rules; hidden/internal fields must not be writable | No | Candidate validation/render/preview binding tests in the UniFFI and C ABI modules |
| Reviewed provider model sync | `start/get/list/approve/cancel/poll_events/ack_event` ([`app/model_sync.rs:87`](../../crates/core/src/app/model_sync.rs#L87)) | Full job-scoped surface ([`lib.rs:2718`](../../bindings/uniffi/src/lib.rs#L2718)) | Full job-scoped versioned JSON surface ([`lib.rs:2309`](../../bindings/c-api/src/lib.rs#L2309)) | Connection ID; transient credential only on start; review SHA for approval; job ID/limit/sequence for reads/ack | Durable `ModelSyncJob`, bounded job `Vec`, durable event `Vec`, boolean ack | Immediate legacy refresh is disabled; review hash and state transitions fail closed | JS supplies no credential; shell resolves it only for start | Explicit job cancellation. Polling/ack are job-scoped | Created/fetching/committing jobs become durable `interrupted`; list rediscovery is supported and no network work is replayed ([`model_sync.rs:746`](../../crates/storage/src/model_sync.rs#L746)) | `start_provider_model_sync(input)`; `get/list/approve/cancel`; `poll_provider_model_sync_events`; `ack_provider_model_sync_event` | No initially; events are durable poll/ack records, not high-speed token deltas | No for start; yes for the other commands | Credential coordination on start. Do not replace the durable event log with an ephemeral Channel-only stream | No | Credential reflection rejection ([`app.rs:6884`](../../crates/core/src/app.rs#L6884)); job-scoped polling ([`app.rs:6914`](../../crates/core/src/app.rs#L6914)); interrupted-job recovery tests in [`storage/src/model_sync.rs`](../../crates/storage/src/model_sync.rs) |
| Provider discovery and reviewed commit | High-level façade for begin/get/list/candidates/evidence/approvals/review/proposals/continue/supply/cancel/commit/recovery/compensation/assistant ([`provider_discovery.rs:4948`](../../crates/core/src/provider_discovery.rs#L4948)) | Typed snapshots and methods ([`lib.rs:2231`](../../bindings/uniffi/src/lib.rs#L2231)) | Versioned JSON snapshots and methods ([`lib.rs:2563`](../../bindings/c-api/src/lib.rs#L2563)) | Sanitized source/input, session/action/approval IDs, discovery `expected_revision`, evidence, review hashes, and transient assistant/target credentials where required | Durable typed snapshot and outbox/event/compensation projections | This subsystem intentionally uses revisioned state transitions and explicit unknown-outcome/compensation errors | Raw cURL and extracted credentials are one-shot. Durable snapshots/evidence/events are secret-free. Vault work is explicit compensation work | Explicit discovery cancellation is revision-checked; it is not chat-generation cancellation | Startup conservatively classifies unfinished work and exposes explicit recovery/compensation state; native effects are not replayed automatically | Corresponding `provider_discovery_*` commands with safe DTOs | No initially; preserve durable poll/ack outbox semantics | No: platform credential actions and compensation require shell coordination | Do not remove discovery `expected_revision`, infer recovery from a coarse state, or expose raw assistant/tool/cURL payloads. Its compensation recipe models only post-failure `remove_credential_slot`; it cannot bracket the initial OS-vault write | No for current discovery semantics; **yes before production removal** for the separate crash-safe credential pre-install lifecycle | End-to-end reopen ([`crates/core/tests/provider_discovery_integration.rs:1007`](../../crates/core/tests/provider_discovery_integration.rs#L1007)); compensation restart ([`crates/core/tests/provider_discovery_integration.rs:1253`](../../crates/core/tests/provider_discovery_integration.rs#L1253)); compensation recipe ([`provider_discovery.rs:3134`](../../crates/core/src/provider_discovery.rs#L3134)); secret-bearing cURL gate ([`crates/core/tests/provider_discovery_integration.rs:1360`](../../crates/core/tests/provider_discovery_integration.rs#L1360)) |
| Signed provider catalog | Prepare/activate import, status/history, diff, prepare/activate rollback ([`catalog.rs:286`](../../crates/core/src/catalog.rs#L286)) | Full projected surface ([`lib.rs:2786`](../../bindings/uniffi/src/lib.rs#L2786)) | Full versioned JSON surface ([`lib.rs:3486`](../../bindings/c-api/src/lib.rs#L3486)) | Signed envelope bytes, reviewed plan, revision IDs, bounded history cursor fields | Status/history/diff/plan/result DTOs | Signature, hash, expiry, stale-plan, and storage failures remain structured and fail closed | No credential | Not cancellable through current public contract | Active state/history persist and are validated after reopen | Corresponding `provider_catalog_*` commands | No | Yes, after DTO projection | Pending import plans are process-local; activation must use the reviewed live plan | No | Reopen/determinism ([`catalog.rs:1556`](../../crates/core/src/catalog.rs#L1556)); tamper/expiry/reuse ([`catalog.rs:1619`](../../crates/core/src/catalog.rs#L1619)); bounded history ([`catalog.rs:1672`](../../crates/core/src/catalog.rs#L1672)) |
| Database statistics | `database_stats()` ([`app.rs:1809`](../../crates/core/src/app.rs#L1809)) | `database_stats()` ([`lib.rs:3058`](../../bindings/uniffi/src/lib.rs#L3058)) | No public C ABI method | None | Counts for characters, conversations, messages, pending imports | Standard storage error | None | Not applicable | Recomputed from persisted DB | `database_stats()` if retained as a diagnostic UI feature | No | Yes, after DTO projection | C ABI coverage is absent | No | UniFFI mapping at [`bindings/uniffi/src/lib.rs:6559`](../../bindings/uniffi/src/lib.rs#L6559) |

The current Tauri stream adapter adds a canonical UUID `stream_id` to
send/edit/regenerate calls and keeps at most 32 forwarding registrations.
`dispose_chat_stream` signals only the identified receiver; its slot remains
counted until that forwarding task exits and drops its registration. The event
verifier requires a non-null branch and assistant message ID, binds the first
assistant ID, and rejects or reconciles identity and sequence changes. These are
adapter controls, not changes to Core's event schema or
generation-cancellation semantics.

The registered `subscribe_generation` command retains its typed request,
sequence baseline, stream ID, and Channel signature for compatibility, but it
returns `generation_reattachment_unavailable` without application state and
before registry, Shell, or Core access. It therefore creates no forwarding
registration.

## Exact chat event v4 contract

`ChatEvent` always carries `event_version`, `generation_id`,
`conversation_id`, nullable `branch_id`, nullable `assistant_message_id`,
per-generation monotonic `sequence`, `emitted_at`, and one `kind`
([`crates/chat/src/events.rs:12`](../../crates/chat/src/events.rs#L12)).

The only Core v4 variants are:

1. `GenerationStarted`
2. `ReasoningDelta(String)`
3. `TextDelta(String)`
4. `ToolCallStarted { id, name }`
5. `ToolCallArgumentsDelta { id, delta }`
6. `ToolCallCompleted { id }`
7. `UsageUpdated(GenerationUsage)`
8. `MessageCommitted { message_id, status }`
9. `GenerationCancelled`
10. `GenerationFailed { code, message }`
11. `GenerationFinished`

These variants are defined at
[`crates/chat/src/events.rs:23`](../../crates/chat/src/events.rs#L23).
`Dropped`, `Reconciled`, `PendingRestored`, and `ToolProposal` are not Core
chat events. If `shell-api` needs a Channel control envelope for lag or
lifecycle, it must use a separately named adapter-level type and must never
present it as a `ChatEventKind`.

UniFFI flattens the variants into a string `kind` plus nullable payload fields
([`bindings/uniffi/src/lib.rs:6568`](../../bindings/uniffi/src/lib.rs#L6568)).
The C ABI serializes the serde-tagged Core enum. Because the frozen bindings
already have different wire layouts, the Tauri DTO should preserve the Core
fields, variants, and ordering semantics rather than copying either legacy wire
shape byte-for-byte.

## Conversation concurrency invariant

There is no conversation-wide revision field in `Conversation`,
`ConversationBranch`, or `ConversationState`
([`crates/domain/src/conversation.rs:44`](../../crates/domain/src/conversation.rs#L44)).
Explicit branch send, edit, regenerate, and remove accept the caller's nullable
`expected_head`. Storage compares it with the selected branch head inside the
same transaction and returns a recoverable stale-branch error on mismatch
([`crates/storage/src/database.rs:988`](../../crates/storage/src/database.rs#L988),
[`crates/storage/src/database.rs:6638`](../../crates/storage/src/database.rs#L6638)).

The first Tauri adapter therefore:

- passes `expected_head` without converting it to a timestamp or revision;
- treats `null` as “the caller expects an empty branch”;
- refreshes conversation state and branch messages after the recoverable
  stale-head error;
- does not add cursor pagination to `list_characters`,
  `list_conversations`, `list_conversation_branches`, or message listing;
- keeps provider-discovery `expected_revision` because that is a separate,
  existing state-machine contract.

## Cancellation, lag, and restart invariant

Core's chat bus is an in-memory `tokio::broadcast` channel with capacity 256.
A new receiver observes only later events. Each Tauri send, edit, or regenerate
operation therefore obtains an independent Core receiver immediately before it
starts that generation, then returns a generation-filtered stream for one
ordered Tauri Channel. The adapter does not own a replay buffer or one
process-wide receiver. Closing a view listener stops only that forwarder; it
does not call `cancel_generation`.

On `Lagged`, the adapter reloads `get_conversation_state` and
`list_branch_messages`. It cannot reconstruct missing token deltas. A non-zero
drop count is a reconciliation signal, not a synthetic Core event. If the
persisted result remains pending, the frontend enters a blocking error state,
retains the generation ID for explicit cancellation, blocks a new send, edit,
or regenerate start, and does not subscribe again.

This fail-closed policy prevents a terminal event from being missed in a new
read/subscription gap and prevents arbitrary canonical identifiers from
consuming bounded registrations: every reattachment is rejected before
admission. It does not provide same-process re-entry parity.

Before reattachment can be enabled, Core must expose either one atomic
operation that validates the live route and returns status, sequence watermark,
and an already-established receiver, or a durable event outbox with equivalent
no-gap semantics. Unknown, terminal, or wrong-route reattachments must still
fail before the Tauri registry admits them. Tests must force terminal
completion at every read/subscription boundary and attempt enough invalid
subscriptions to prove that capacity cannot be exhausted.

Process restart is not generation resume. During Storage open, every
`running` generation becomes `cancelled`. If
`preserve_partial_generations` is enabled, the pending assistant becomes a
cancelled persisted message; otherwise Core removes it and rewinds affected
branch pointers
([`crates/storage/src/database.rs:5925`](../../crates/storage/src/database.rs#L5925)).
The frontend must display that persisted outcome and must not automatically
repeat provider side effects.

The current public Core has no `get_generation`,
`list_active_generations`, or atomic reattachment method. Message content,
status, branch head, and generation ID can be queried today, but those separate
reads are insufficient to re-enable live reattachment safely. Reconstructing
persisted usage after dropped events additionally requires a read-only Core
projection.

## Credential invariant

Core persists only an opaque `CredentialRef` and an exact origin/auth
`CredentialScope`
([`crates/domain/src/provider.rs:689`](../../crates/domain/src/provider.rs#L689)).
The native platform vault owns secret storage. Current generation, model-sync,
and relevant discovery operations borrow plaintext only for the active
operation. Existing tests verify that credentials are not persisted and that
provider reflection is rejected before it reaches events, partial state, or
SQLite
([`crates/core/tests/chat_vertical_slice.rs:219`](../../crates/core/tests/chat_vertical_slice.rs#L219),
[`crates/core/tests/chat_vertical_slice.rs:351`](../../crates/core/tests/chat_vertical_slice.rs#L351)).

Stored credentials are never returned to JavaScript. Ordinary generation,
model-sync, discovery-assistant, credential-status, and read flows accept only
a connection or generation target identifier. A dedicated credential
create/update command may accept a transient secret entered in the trusted
product WebView. It must best-effort clear that value immediately after the
command and must never persist it in frontend state/storage, log it, emit it,
return it, or include it in errors. JavaScript strings cannot be guaranteed to
be physically zeroized; a threat model requiring that property needs a native
secure-input surface.

No Tauri output or non-credential command may expose:

- a stored or transient API key or authorization header;
- raw cURL credential material;
- a `CredentialRef` string;
- a private provider request/prompt body.

For ordinary operations the frontend supplies a connection or generation
target identifier. `shell-api` validates the Core-facing target. The Tauri
application adapter asks its sibling platform plugin for the matching vault
slot, passes the secret directly into one `shell-api`/Core operation, and
releases it. Frontend projections contain only `available`, `missing`, or an
explicit bounded error state. Credential create/update/delete and Core
connection mutation remain a compensating workflow; a vault failure must not be
collapsed into “missing”.

The current Tauri backend preserves the native clients' in-process rollback
when a vault mutation succeeds but the matching Core mutation fails
([`provider_commands.rs:316`](../../apps/lorepia/src-tauri/src/provider_commands.rs#L316)).
That is not crash safety. Core discovery's durable `Compensating` state and
`RemoveCredentialSlot` step are a post-failure removal recipe
([`provider_discovery.rs:3134`](../../crates/core/src/provider_discovery.rs#L3134));
they do not record a pre-commit intent or outcome around the initial OS-vault
write. They must not be reused as if they were that write journal. A process
exit between vault installation and Core commit therefore remains
unreconciled. Before any native client is production-removable, Core/storage
needs a separate durable credential-install state machine, startup
reconciliation, and crash/failure-injection tests covering every boundary.
