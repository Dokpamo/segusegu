# Testing

The migration and release require the following validation layers. Their
presence in this guide is not evidence that each layer has been implemented or
executed; every result report lists current evidence and blockers:

1. Rust unit tests for parsing, path policy, prompt order, events, repositories,
   providers, and ownership;
2. Rust vertical tests for import, persistence, restart, and generation;
3. `shell-api` tests for bounded input, current-Core semantic mapping, safe UI
   projections, stable errors, secret/path redaction, event ordering, Channel
   disposal, cancellation, and persisted-state reconciliation;
4. Svelte/TypeScript format, lint, type, unit/component, accessibility, state,
   and production-build checks;
5. Tauri integration tests against project-owned synthetic fixtures and a live
   Core, including bootstrap, import, conversations, chat, provider settings,
   background/resume, and process restart;
6. Android, iOS, macOS, and Windows Tauri build/install/launch smokes on matching
   hosts;
7. frozen native binding, ViewModel, navigation, and launch checks used only as
   behavioral-reference and old-to-new upgrade evidence.

Run the host-independent mainline checks with:

```bash
./scripts/check.sh
./scripts/check-tauri.sh
```

Executed checks, CI-only checks, host-blocked checks, and signing-asset-blocked
upgrade checks must be reported separately. A scaffold, package install,
frontend build, or frozen native build does not prove a platform launch,
feature parity, data continuity, credential continuity, or release readiness.

Synthetic hostile archives live in `testdata/`. Regenerate them with
`cargo xtask testdata regenerate`. A test must never require user data or a live
model credential.

## CI contract checks

The CI path filter has an explicit Tauri scope covering the application,
shared Rust crates, platform plugin, testdata, lockfiles, policy scripts, and
workflow. It rejects unknown scopes, treats missing Git endpoints or a failed
diff as requiring checks, and consumes NUL-delimited paths. Its repository-job
self-test checks selected mappings only; it does not create a temporary Git
repository to exercise rename, copy, and delete behavior. The Android and Apple
scopes include `testdata`; the remaining path-filter gap is broader executable
coverage for rename, copy, delete, and failure cases rather than fixture-scope
omission.

The repository job regenerates synthetic archives/packages and verifies the
allowed `testdata` file-name manifest. The hand-authored
`testdata/tauri-upgrade/platform-contract.json` is included in that name list,
but `cargo xtask testdata regenerate` does not generate or semantically
validate it, and the job does not currently compare regenerated fixture bytes
with Git. Treat the JSON as a reviewed declarative contract until an executable
schema/source-evidence validator and content-drift check exist.

Windows [`check.ps1`](../../scripts/check.ps1) enforces the pinned Node version,
locked npm install, dependency-license and Tauri-capability checks, frontend
checks, all required Rust checks, and repository policy with explicit exit-code
propagation. It is a hardened local aggregate entrypoint whose changes trigger
the Tauri path filter; no hosted workflow currently invokes that script
directly.

Android CI has source-text count/reference assertions for the plugin manifest
and its deny-only backup/data-extraction XML, and byte-compares both XML files
with the frozen native baseline. The product import flow uses
`ACTION_OPEN_DOCUMENT` plus a bounded private copy and does not require
`FileProvider`. The generated WebView camera chooser separately requires a
non-exported provider; deterministic aftercare limits it to the app-owned
external-files `Pictures/` directory. The configured APK assertions inspect
`versionCode=2`, the merged provider, the compiled path element/name/value, the
absence of general external/cache/files/root paths, backup references, and
broad storage/media permissions. No clean hosted result is recorded yet.

These are source controls and documented gaps, not a claim that hosted jobs are
green.

## Tauri boundary and stream tests

Every exposed command needs success, invalid-input, stable-error, and redaction
coverage. JavaScript tests must not open SQLite, use unrestricted absolute
paths, or receive credential material. File tests use opaque tickets backed by
bounded app-owned synthetic transport files.

High-rate chat tests use an ordered Channel and validate at least event version,
generation, conversation, branch, pending assistant, monotonically increasing
sequence, one terminal outcome, explicit cancellation, listener disposal, and
re-entry reconciliation. Wrong-scope, duplicate, decreasing, stale-lifecycle,
post-terminal, and unsupported-version items are rejected or reconciled.
Dropped or lagged Core events force a persisted-message reload.

Re-entry tests must force a generation to become terminal at every boundary
between the persisted read and listener installation. Passing requires a
Core-owned atomic status-plus-watermark subscription or durable outbox; a
separate read followed by a broadcast subscription is not sufficient. Unknown,
already-terminal, and wrong-conversation/branch generation IDs must fail before
they occupy a bounded stream registration, and repeated invalid attempts must
not exhaust capacity.

Until that contract exists, production Tauri keeps reattachment disabled. Its
registered command returns `generation_reattachment_unavailable` before
application state, registry, Shell, or Core access, and the frontend does not
invoke it. Tests must preserve the stable nonrecoverable error, prove that more
than the registry capacity of rejected attempts consume no slots, and verify
that a persisted pending generation produces an accessible blocking alert while
retaining its ID for explicit cancellation and blocking a new send, edit, or
regenerate start.

## Upgrade fixtures

Production-identity continuity is tested only with project-owned synthetic data
in a disposable environment:

1. seed a database, assets, settings, selected route/preset, and synthetic
   credential through the frozen native baseline harness;
2. install or update to the Tauri app using the controlled production test
   identity and signing lineage;
3. open the existing platform data root without a silent framework-default
   relocation;
4. verify database, assets, route/preset selection, and credential availability;
5. complete a synthetic authenticated request without exposing the secret to
   frontend state, errors, logs, or Channel items;
6. where supported, have the old harness read back the Tauri-written synthetic
   value and verify rollback leaves the database uncorrupted.

Real user installations, production databases, and real API keys are forbidden.
If production signing or a target OS is unavailable, the corresponding result
is blocked, not passed.

## Input, accessibility, and UI performance

Release evidence covers Korean composition without Enter submission, Japanese
conversion, Chinese Pinyin, multiline input, text selection/copy, mobile
keyboard behavior, safe areas, platform back behavior, and desktop shortcuts.
Accessibility evidence covers semantic markup, labels, focus order,
keyboard-only use, reduced motion, text scaling, contrast, VoiceOver, TalkBack,
Narrator, and macOS keyboard/accessibility smoke.

Performance measurements intentionally have no pass/fail duration threshold.
Run the ignored suite explicitly and retain its printed timings when comparing
revisions:

```bash
cargo test -p lorepia-core --test performance_scenarios -- --ignored --nocapture
```

Every scenario uses temporary, project-owned synthetic data. It requires no
external network, credential, user content, or repository fixture:

- reopen and list a 1,000-character library;
- persist and load 100,000 message metadata rows;
- inspect a CHARX package with a 32 MiB asset;
- inspect and enumerate a CHARX package containing 2,000 assets;
- process 4,096 ordered streaming chunks;
- run 100 consecutive cancellation and regeneration cycles;
- reopen persisted library and conversation data while recovering abandoned
  staging work.

The suite prints elapsed times and workload counts but makes only functional
assertions. Establish a regression threshold only after comparable measurements
show a stable baseline.

Tauri UI measurements use the same synthetic fixtures and matching devices or
runners. Record OS, device, build mode, fixture size, repetitions, cold/warm
start, idle and long-chat memory, visible DOM bound, scroll stability, delta
batching, 10,000-message rendering, 4,096-item Channel delivery, repeated
send/cancel or regenerate/cancel, background/resume, and process restart.
