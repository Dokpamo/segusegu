# Platform continuity gates

- Contract: [`testdata/tauri-upgrade/platform-contract.json`](../../testdata/tauri-upgrade/platform-contract.json)
- Native baseline tag: `native-baseline-before-tauri-2026-08-02`
- Native baseline commit: `66e398fa6256f17b04c82569e6764a9e5332265c`
- Current execution status: **BLOCKED**
- Last status update: 2026-08-03

## Purpose

This document defines the signed old-native-to-Tauri continuity and technical
rollback fixture. It is a production-release and native-source-removal gate,
not a Tauri adoption gate.

The test proves that a Tauri release can replace or succeed the frozen native
client without losing the existing synthetic Core database, content-addressed
assets, provider target selection, or platform credential. It also proves one
authenticated request against a disposable local fixture server without
returning the credential to JavaScript.

The checked-in contract is hand-authored and declarative. The current
`cargo xtask testdata regenerate` command does not generate it, and CI has no
executable schema or source-evidence validator for it. It does not claim that a
continuity run has occurred.

## Current status

No platform has completed this gate.

Every platform also shares one implementation blocker: Core/storage has no
durable credential-install intent/outcome around the initial OS-vault write and
matching Core commit. The current Tauri backend provides only in-process
rollback. The existing provider-discovery `Compensating` state contains
post-failure removal work and cannot be treated as that pre-install journal.
The separate state machine, startup reconciliation, and crash/failure-injection
suite must pass before a signed continuity run can clear native removal.

Native removal also shares an ordered-chat product-parity blocker. Production
Tauri now keeps same-process reattachment fail-closed: the registered command
returns `generation_reattachment_unavailable` without application state and
before registry, Shell, or Core access. The frontend does not call it and shows
a blocking alert for a still-pending persisted generation while retaining its
ID for explicit cancellation and blocking new generation starts. Repeated
rejected attempts consume no bounded adapter slots, so the previous terminal-gap
and invalid-subscription capacity paths are not reachable through production
Tauri.

That safe failure is not re-entry parity. A Core-owned atomic live-route,
status/watermark, and already-established-receiver contract or durable outbox,
plus forced boundary and saturation tests, is required before reattachment can
be enabled and native removal can pass.

| Platform | Status | Current blocker |
|---|---|---|
| Android | **BLOCKED** | The shared credential state-machine code gate is pending. The production signing certificate lineage, authorized release keystore, and signed native/Tauri artifacts are external to this repository. |
| iOS | **BLOCKED** | The shared credential state-machine code gate is pending. The prior Apple Team ID, effective default Keychain access group, distribution provisioning, and signed native/Tauri artifacts are external to this repository. |
| macOS | **BLOCKED** | The shared credential state-machine code gate is pending. The Rust backend reads and verifies the exact accessibility attribute, uses a no-pre-delete upsert, and its current 23-test Rust suite passes. Real system-Keychain behavior, targeted interruption/failure cases, and signed continuity have not passed. The prior Apple Team and distribution identity, effective default Keychain access group, delivery configuration, and signed native/Tauri artifacts are external to this repository. |
| Windows | **BLOCKED** | The shared credential state-machine code gate is pending. The baseline is unpackaged and has no package or installer upgrade identity. A Tauri production installer identity and signing lineage must first be defined, then PasswordVault continuity must be exercised on Windows. |

Source-only builds, unit tests, an unsigned launch, a newly installed empty
Tauri app, or a development identity do not clear these blockers.

## Fixture safety boundary

Every run uses a disposable simulator, emulator, VM, or test device and only
project-owned synthetic data.

Allowed inputs are:

- `testdata/packages/with-avatar.charx`;
- generated synthetic chat text and identifiers;
- a runtime-generated disposable credential;
- a disposable local authenticated HTTP fixture server; and
- redacted logs, hashes, boolean authentication results, screenshots, and
  semantic manifests.

The following are prohibited:

- an actual user database or user content;
- a real provider account or API key;
- a production device snapshot;
- a raw authorization header in logs or evidence;
- a credential value in JavaScript state, a Tauri event, a command result, a
  screenshot, a committed file, or CI output; and
- an external network request.

The fixture server receives a runtime-generated credential only so it can
report `authenticated_match=true` or `false`. It must not persist or echo the
header. Evidence may retain a one-way fingerprint generated before the run,
but never the raw value.

## Fixed baseline contract

The continuity harness must load
[`platform-contract.json`](../../testdata/tauri-upgrade/platform-contract.json)
and fail before installation if its tag, commit, schema, or production identity
does not match the artifacts under test. That executable harness and semantic
validator are not implemented yet.

The fixed shared storage contract is:

- existing Core root opened in place;
- schema version `11`;
- database at `db/lorepia.sqlite3`;
- SQLite WAL and SHM sidecars treated as database state;
- source packages under `sources/sha256`;
- assets under `assets/sha256`;
- Core staging under `staging`; and
- no automatic provider request replay during startup or recovery.

The authoritative platform identities, roots, staging paths, backup rules, and
credential identifiers are in the JSON contract. The human-readable native
snapshot is in [native-baseline.md](native-baseline.md).

Development Tauri identities must be distinct and coinstallable, but they
cannot prove production continuity: a distinct identity must not open the
production sandbox, data root, or credential store.

The configured development identities are now fixed as
`dev.lorepia.app.dev`, `dev.lorepia.ios.dev`, `dev.lorepia.mac.dev`, and
`dev.lorepia.windows.dev`. Source configuration is not proof of effective
coinstallation or isolation. Likewise, one shared source-level Tauri
`identifier` is not proof of the effective Android, iOS, macOS, and Windows
release identities. The run records the installed identity resolved by each OS,
requires the configured development identity to differ from production, and
fails on an iOS or macOS bundle-ID substitution.

Windows source configuration now uses `dev.lorepia.windows` for production.
That string is configured, not `UNASSIGNED`, but it does not prove a package
identity, installer upgrade key, signing lineage, installed behavior, or
continuity from the unpackaged native baseline. Those facts remain blocked.

The production source configuration also advances every inherited mobile and
Apple build sequence: Android `versionCode` is `2`, while the frozen native
value is `1`; iOS and macOS `bundleVersion` are `2`, while the frozen native
`CURRENT_PROJECT_VERSION` is `1`. This is the minimum monotonic source
configuration, not update evidence. A run must still inspect the packaged
artifact and prove that the target OS accepts it over the signed build `1`.
Windows has no inherited installer sequence to compare until its package or
installer identity is defined.

## Required run inputs

Record these inputs before seeding:

1. run ID and UTC start time;
2. target OS, version, architecture, device or runner model, and whether it is
   a simulator, emulator, VM, or physical test device;
3. baseline tag object and peeled commit;
4. old-native artifact digest, version/build, observed product identity, and
   non-secret signer or Team fingerprint;
5. Tauri artifact digest, version/build, observed product identity, and
   non-secret signer or Team fingerprint;
6. installer/update mechanism;
7. expected Core root resolved by native platform code;
8. local fixture server origin and certificate mode, without credential data;
9. a redaction-check result for both applications and the fixture server; and
10. the rollback artifact or whole-target snapshot strategy.

An artifact compiled from the right commit but signed under the wrong lineage
is not the baseline upgrade input.

## Execution procedure

### 1. Prepare the disposable target

1. Start from a clean disposable target.
2. Record the target and OS metadata.
3. Ensure no previous Lorepia installation, data root, credential record, or
   stale fixture server remains.
4. Create a whole-target snapshot when the platform supports it.
5. Do not rely on Android backup, Apple cross-device restore, or a copied
   password-vault file. Android backup is disabled and Apple credentials use a
   `ThisDeviceOnly` accessibility class.
6. Start the local fixture server on a target-reachable loopback or isolated
   test-network address.
7. Generate the disposable credential in memory and provide it separately to
   the fixture server and the old native credential input.

### 2. Install and seed the frozen native client

1. Install the signed old-native artifact built from the annotated baseline
   tag.
2. Verify its observed product identity and signer lineage before launch.
3. Launch the real native client, not a preview, fake Core, fixture-only app
   mode, or UI mock.
4. Verify that Core reports schema version `11` and a healthy writable root.
5. Import `testdata/packages/with-avatar.charx`.
6. Capture the generated character ID, source hash, and asset hashes.
7. Create one provider connection pointing only at the local fixture server.
8. Store the disposable credential through the real platform credential
   boundary.
9. Create one model route and one generation preset, then persist that pair as
   the selected target.
10. Create one conversation and branch with deterministic synthetic user and
    assistant content.
11. Close the application cleanly and wait for the Core owner lock to be
    released.

The seed harness records identifiers returned by Core. It must not hard-code or
derive product IDs in JavaScript and must not query SQLite from the application
frontend.

### 3. Capture the pre-update semantic manifest

Capture a secret-free manifest containing:

- Core, binding, ChatEvent, and schema versions;
- resolved Core root description;
- database statistics;
- character ID and source hash;
- asset hashes, byte sizes, and successful Core-mediated reads;
- provider connection, route, and preset IDs;
- selected connection, route, and preset;
- conversation, branch, and message IDs plus hashes of synthetic text;
- credential status `available`, without the credential reference or value;
- installed backup/data-protection settings; and
- a redaction scan result.

After the old application has closed, either snapshot the entire disposable
target or copy the entire synthetic Core root as one offline fixture. Copying
only `lorepia.sqlite3` is invalid because WAL/SHM and content-addressed files
are part of the state. A Core-root copy is not a Keychain, Keystore, or
PasswordVault backup; whole-target snapshots or signed rollback artifacts are
needed for credential rollback.

### 4. Apply the Tauri production update

Install the Tauri artifact using the platform's real production cutover path.
Do not uninstall the old app first when uninstalling would delete its sandbox
or credentials.

- Android must retain `dev.lorepia.app` and an accepted production signing
  lineage, and the installed `versionCode` must be greater than native build
  `1`.
- iOS must retain `dev.lorepia.ios`, the Apple Team lineage, and the effective
  default Keychain access group; the installed `CFBundleVersion` must be
  greater than native build `1`.
- macOS must retain `dev.lorepia.mac`, the sandbox-container identity, Apple
  Team lineage, and effective default Keychain access group; the installed
  `CFBundleVersion` must be greater than native build `1`.
- Windows has no inherited package upgrade identity. Install the newly defined
  Tauri production package or installer, then explicitly open
  `%LOCALAPPDATA%\LorePia` and test PasswordVault access against the item seeded
  by the unpackaged native executable.

Record installer output, observed installed identity, signer fingerprint,
artifact digest, and whether the OS classified the operation as an update,
replacement, or first packaged install.

### 5. Verify Tauri continuity

Launch the installed production Tauri application and require all of the
following:

1. It opens the existing Core root in place and does not create or select a
   framework-default alternate root.
2. Core opens schema version `11` without destructive recovery or an
   undocumented migration.
3. The post-update semantic manifest matches the pre-update manifest for all
   persisted IDs, counts, hashes, branch heads, and selected provider target.
4. The imported character and its asset metadata/hash are readable through Core
   from the existing content-addressed store. The initial Tauri UI may retain
   the same placeholder presentation as the frozen native surfaces; actual
   artwork rendering is a separate secure asset-protocol release feature.
5. The provider connection, model route, generation preset, and selected target
   are unchanged.
6. The platform plugin reports the seeded credential as available without
   returning its reference or value to JavaScript.
7. A generation or model request is sent once to the local fixture server using
   that credential.
8. The fixture server reports exactly one accepted request and
   `authenticated_match=true`.
9. The synthetic response is persisted through the normal Core path.
10. JavaScript state, command and Channel payloads, logs, errors, screenshots,
    database text, and fixture-server evidence contain no credential or raw
    authorization header.
11. The installed application retains the platform backup and data-protection
    contract.
12. Closing Tauri releases the Core owner lock cleanly.

On macOS, item availability and a matching value are insufficient. The run must
also prove that Tauri reads and asserts
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, preserves the exact prior
record on restoration, uses the no-pre-delete replacement path, and cannot lose
the prior protected item at any injected Keychain mutation, verification,
restoration, or matching Core-commit interruption boundary.

Any alternate data root, re-entered credential, recreated provider target,
missing asset, changed persisted identity, implicit external request, or secret
exposure is a failure.

### 6. Optional old-native reread

This diagnostic is optional for an ordinary continuity run and must be recorded
as `NOT_RUN`, `PASS`, or `FAIL`; omission is never represented as `PASS`.

1. Close Tauri and verify owner-lock release.
2. Use the same disposable target or an exact target snapshot.
3. Start an old-native build compatible with the platform's version and signing
   rules.
4. Open the post-Tauri Core root without copying or converting it.
5. Verify the character, asset, provider target, conversation, branch, and
   Tauri-persisted synthetic response.
6. Verify credential availability without making an external request.

Do not force an OS downgrade or weaken signing policy to run this diagnostic.
Use a purpose-built, monotonically versioned rollback artifact when required.

### 7. Exercise technical rollback

A production-release gate requires a rollback drill even when the optional
diagnostic above was not run.

Preferred rollback is a signed release containing the frozen native client code
with a version/build accepted over the Tauri release:

The original frozen build `1` cannot be assumed installable over configured
Tauri build `2`. For channels that enforce monotonically increasing builds,
package the frozen code under the same authorized identity and signing lineage
with an accepted build number greater than `2`. A whole-target snapshot restore
is disaster-recovery evidence, not proof of an in-place application rollback.

1. close Tauri and verify owner-lock release;
2. install the signed rollback artifact without deleting the data sandbox;
3. open the current schema-11 Core root;
4. compare the semantic manifest, including data added by Tauri;
5. verify credential availability and one local authenticated request;
6. close the rollback client cleanly; and
7. record the installer, identity, signer, semantic, authentication, redaction,
   and owner-lock evidence.

If a platform cannot perform an in-place rollback in the test channel, restore
the whole disposable target snapshot and rerun the old-native read checks.
Snapshot restoration proves disaster recovery but does not by itself prove
that a production code rollback can preserve data written after the update.
Record that limitation as `BLOCKED`, not `PASS`.

Never restore a partial live SQLite directory and never attempt to export or
reconstruct a platform credential key.

## Platform-specific pass conditions

| Platform | Required additional proof |
|---|---|
| Android | Installed `versionCode` is greater than frozen native build `1`; the manifest retains `allowBackup=false`; full/cloud/device-transfer exclusions remain effective; no broad storage/media permission is introduced; the non-exported WebView camera `FileProvider` grants only the app-owned external-files `Pictures/` path and no general external/cache/files/root path; ciphertext remains under `noBackupFilesDir/provider-credentials`; existing version-1 AES-GCM record using alias `dev.lorepia.provider-credentials.v1`, connection-ID AAD, and SHA-256 filename is readable. |
| iOS | Installed `CFBundleVersion` is greater than frozen native build `1`; the bundle and Team resolve to the prior application identity; the same-device Data Protection Keychain generic-password item is readable with service `dev.lorepia.provider-credentials`, the seeded account, and `WhenUnlockedThisDeviceOnly`; no new data root is selected. |
| macOS | Installed `CFBundleVersion` is greater than frozen native build `1`; the signed sandbox replacement resolves to the existing container; the production Data Protection item and any tested legacy-to-protected migration remain readable; the exact `WhenUnlockedThisDeviceOnly` attribute is read and verified; replacement uses the no-pre-delete update path and survives every injected Keychain mutation, verification, restoration, and matching Core-commit boundary without losing the prior item; user-selected read-only and network-client entitlements remain effective. |
| Windows | Evidence explicitly distinguishes first packaged install from an inherited update; `%LOCALAPPDATA%\LorePia` opens in place; the Tauri credential plugin retrieves resource `LorePia.ProviderCredential` with the seeded connection ID as user name across the unpackaged-to-new-installer boundary. |

## Result rules

Use only these statuses:

- `BLOCKED`: execution cannot proceed because required implementation,
  artifact, signer, host, identity decision, or authority is missing;
- `NOT_RUN`: an optional step was not executed;
- `PASS`: the step completed and its required evidence is attached;
- `FAIL`: the step executed and any required assertion failed.

`PASS` requires evidence. A missing attachment, inaccessible CI artifact,
truncated log, unreviewed redaction failure, or pending job changes the result
to `BLOCKED` or `FAIL` as appropriate.

The overall platform result is:

- `PASS` only when seed, update/cutover, semantic continuity, asset continuity,
  provider target continuity, credential continuity, local authenticated
  request, durable credential-install crash reconciliation,
  backup/data-protection verification, redaction, clean shutdown, and rollback
  all pass;
- `FAIL` if any executed required assertion fails; or
- `BLOCKED` when any required step has not been executable.

The optional old-native reread does not affect a continuity-only sub-result,
but a failed reread blocks schema round-trip claims and must be resolved before
native-source removal.

## Evidence record

Create one record per platform run in the release system or durable CI
artifact. Do not commit signed binaries, credentials, platform vault exports,
or user-derived data to this repository.

| Evidence field | Value |
|---|---|
| Run ID | `UNASSIGNED` |
| Platform / OS / architecture | `UNASSIGNED` |
| Target kind and model | `UNASSIGNED` |
| Start / end UTC | `UNASSIGNED` |
| Baseline tag object / peeled commit | `UNASSIGNED` |
| Old-native artifact digest / version | `UNASSIGNED` |
| Old-native observed identity / signer fingerprint | `UNASSIGNED` |
| Tauri artifact digest / version | `UNASSIGNED` |
| Tauri observed identity / signer fingerprint | `UNASSIGNED` |
| Installer or update mechanism and result | `UNASSIGNED` |
| Resolved Core root | `UNASSIGNED` |
| Pre-update semantic manifest digest | `UNASSIGNED` |
| Post-update semantic manifest digest | `UNASSIGNED` |
| Database/schema result | `UNASSIGNED` |
| Source and asset result | `UNASSIGNED` |
| Provider connection/route/preset result | `UNASSIGNED` |
| Credential availability result | `UNASSIGNED` |
| Local authenticated request count / match | `UNASSIGNED` |
| Backup/data-protection result | `UNASSIGNED` |
| Secret/redaction scan result | `UNASSIGNED` |
| Owner-lock shutdown result | `UNASSIGNED` |
| Optional old-native reread | `NOT_RUN` |
| Rollback artifact or snapshot method | `UNASSIGNED` |
| Rollback result | `UNASSIGNED` |
| Logs / screenshots / CI artifact references | `UNASSIGNED` |
| Reviewer / review UTC | `UNASSIGNED` |
| Overall status | **BLOCKED** |
| Blocking or failure reason | `Signed continuity run not yet executed.` |

## Failure handling

On failure:

1. stop the run and preserve only redacted evidence;
2. do not retry a credential-bearing network operation automatically;
3. do not delete or mutate the failed synthetic target before capturing the
   semantic and installer evidence;
4. restore or recreate only the disposable test environment;
5. classify the failure as identity, signing, data-root, schema, asset,
   provider target, credential, request, redaction, shutdown, or rollback;
6. fix the identified boundary in the Tauri mainline; and
7. rerun the full platform sequence from a clean old-native seed.

Never repair the fixture by manually moving a database into the Tauri default
directory, re-entering the credential, changing the expected hashes, or
marking an unavailable platform as passed.

## Scope exclusions

This fixture does not replace functional parity, IME, accessibility,
performance, lifecycle, security, or store-submission gates. It contributes
only signed identity, update/cutover, data, credential, authenticated local
request, and technical rollback evidence to those larger release gates.
