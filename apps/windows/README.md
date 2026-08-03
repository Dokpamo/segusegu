# LorePia for Windows

## Overview

> **Migration status:** This directory is the frozen native Windows
> compatibility, behavioral-reference, and upgrade-test harness. New product
> features belong to the Tauri mainline under `apps/lorepia`. This implementation
> remains only until the documented parity, data, credential, accessibility,
> IME, build, and upgrade gates pass.

The retained Windows baseline is a native WinUI 3 application over the Rust C
ABI:

- `Lorepia.App` owns WinUI navigation, file selection, bounded transport
  staging, PasswordVault credentials, view models, and application lifetime.
- `Lorepia.Native` owns every P/Invoke declaration, native handle and buffer,
  structured error mapping, JSON DTO, and the high-level `CoreClient`.
- `Lorepia.Native.Tests` exercises the high-level ABI, JSON and event mapping,
  buffer and handle lifetime, bounded-copy and event-filtering logic, plus an
  opt-in live Rust DLL vertical slice.

The process creates exactly one `CoreClient` and therefore one
`SafeCoreHandle`. The application composition root injects that shared client
into every view model and disposes it after the main window closes.
`Lorepia.App` calls only the public high-level `CoreClient`; it never calls
`NativeMethods`, parses content packages, or accesses SQLite.

The behavior below documents the retained native baseline. A successful build
or test in this directory is baseline evidence and does not by itself establish
Tauri parity or production release readiness.

### Import and Library

Import Review accepts CCv3 JSON and CHARX packages, including `.zip` archive
selections handled by Rust's CHARX-compatible inspection path. Windows copies
the selection into `%LOCALAPPDATA%\LorePia\transport-staging` with a hard
128 MiB streaming limit, then passes only the absolute staged path to Rust.
Rust creates its own inspection snapshot and returns the name, description,
content kind, storage estimate, warnings, blocked reasons,
representative-image metadata, and unsupported optional CCv3 fields.

The representative image value contains only an archive logical identifier,
media type, and byte count. It is not a Rust staging path or raw preview bytes.
The transport copy is deleted after inspection. Cancel and navigation away
call `discard_import`; Approve calls `commit_import` and returns to a refreshed
Library. Abandoned transport files are cleaned before the next staging
operation. Character rows open or restore that character's chat.

### Chat

Chat restores the newest local conversation or opens one after a Library
selection. It loads persisted messages, provider connections, model routes,
generation presets, and app settings through `CoreClient`.

Send retrieves the selected connection's secret from Windows PasswordVault,
passes it separately from the selected model-route and generation-preset JSON
only for that generation call, and then polls bounded event batches.
Immediately before the secret-bearing native call, `CoreClient` revalidates
that the route belongs to that connection and the preset belongs to that
route; a mismatched or stale graph response fails before the credential
crosses the ABI. Each page activation has a lifecycle epoch. Navigation away
cancels that epoch, so a late load or accepted send cannot mutate the detached
view model or restart its event poller.
Only the exact missing-entry HRESULT is treated as an absent optional
credential; other PasswordVault or COM failures are surfaced. The view model
accepts events only when the conversation ID and generation ID match and the
sequence is strictly increasing. A dropped-event count triggers a persisted
message refresh. Commit, finish, failure, and cancellation also refresh
persisted messages. A pending assistant generation is resumed after navigation
or restart and can be cancelled explicitly. Tool calls are displayed as inert
proposals; the Windows app does not execute them.

### Provider settings

Rust owns the `ProviderTemplate -> ProviderConnection -> ModelRoute ->
GenerationPreset` graph. Windows renders the high-level contracts and never
reads SQLite or parses provider manifests independently.

An API credential is stored only in Windows PasswordVault with resource
`LorePia.ProviderCredential` and the connection ID as its user name. It is
never included in connection, route, preset, settings, catalog, log, or event
JSON. A blank credential field preserves the existing secret; users can remove
it explicitly. Vault and Core writes use compensating transactions, credential
drafts are invalidated when selection or ID changes, and an existing
connection cannot be silently retargeted to another template or credential
origin. Connection updates send only the non-secret flattened ABI fields plus
an exact `credential_slot_ready` result from PasswordVault; Windows never
round-trips a caller-supplied credential reference, and Core derives the
reference from the immutable connection ID.
Because Windows has no Core-visible credential generation, a nonblank
credential cannot replace an existing connection's slot: changing provider
accounts requires a new generated connection ID, route, and preset so opaque
reasoning state cannot cross accounts. A blank field still retains the current
credential, and a rejected non-secret configuration edit never rewrites the
vault.

Provider setup supports a known template, official website, local server, or
official cURL example. Core inspects cURL input first; Windows writes any
returned credential only to the exact internally generated PasswordVault slot,
clears the paste control, and gives discovery only the parseable redacted cURL.
Website and cURL discovery receive safe generated display names, so an unknown
provider can begin from its official URL or example plus a credential without a
separate naming step.
Fresh cURL evidence after restart reuses the schema-3 snapshot's persisted
connection options, including its exact LAN origin and pinned addresses.
Website and cURL setup may request assistant help only through the exact model
route and generation preset already saved as the application default. Windows
offers that pair only while the route is available, the preset still validates,
and any required PasswordVault credential exists. If no executable default
pair exists, the assistant request is disabled and fresh deterministic
discovery still starts with a null preferred assistant route. A restored
pre-grant snapshot does not expose that frozen input route, so Windows never
substitutes a newer application default: the user must add deterministic
evidence or cancel and restart. Once Core proposes the typed assistant grant,
Windows restores only its exact route and shows the assistant
connection/model/preset identity, allowed document origins, evidence IDs,
call/token/tool/retry/cost ceilings, approval ID, and grant digest. A dedicated
approve or decline click is required; the earlier request checkbox and generic
Continue action cannot approve that grant.

Durable discovery snapshots include a typed setup-assistant resume boundary.
Windows reconstructs evidence questions and draft review after restart. A
pending allowlisted Core host action can be resumed explicitly without
exposing a raw tool call or making a model call. Interrupted, retryable, and
unknown outcomes are never replayed automatically. Native credential
compensation starts only an unattempted step bound to the pending connection
ID and an equal opaque credential reference; an uncertain PasswordVault
deletion is marked outcome-unknown and requires manual reconciliation.
Discovery and model-sync responses are accepted only when their session or job,
connection, and compensation attempt still match the requesting operation.
Cancelling while discovery creation is in flight records
the cancellation against that start epoch; when Core returns the exact session,
Windows cancels it without activating the snapshot or starting a monitor.
Leaving Settings also advances a page-lifecycle epoch. Late settings refresh
or model-sync start results are discarded, cannot reapply detached state, and
cannot recreate discovery or model-sync monitors after unload.

Model listing runs as a durable Core model-sync job. Windows polls progress,
stops at the exact review digest, and commits only that approved digest.
Interrupted jobs are shown for recovery and are not automatically replayed.
Missing models remain reviewable as temporarily missing. Route controls use
Core's effective parameter specifications, while capability rows show source,
freshness, alternatives, and conflicts.

Generation presets preserve explicit provider-default states for dynamic
parameters, reasoning, and prompt-cache controls. An unsaved candidate is
validated by Core and rendered as a redacted request preview before
persistence. The preview contains only method, origin, path, header names, and
a scalar-free body shape; any private-message, credential, or opaque-reasoning
leak flag fails closed. New drafts default opaque reasoning replay off.
Credential-bearing connections always load, preview, and persist that setting
as false; Windows disables the continuity control for those targets even if a
stale stored preset or control response says true. Only an exact
credential-free target can opt into the model-specific value returned by Core.
Settings store an exact model-route and preset pair as the default chat target.
Legacy provider-profile settings are read only for migration compatibility.

Signed provider catalogs can be imported from a bounded local JSON file,
reviewed through the ABI's categorized provider/model diff, and activated or
rolled back only by returning the exact opaque `plan_json` retained from the
state-bound prepared plan.

### C ABI contract

`bindings/c-api/include/lorepia.h` at the repository root is the source of
truth. `apps/windows/include/lorepia.h` is its checked-in mirror. ABI version 7
covers:

- core create, destroy, version, health, and structured last error;
- inspect, commit, and discard import plus character get and list;
- conversation and branch operations plus message listing;
- targeted send, cancel, and bounded event polling;
- app settings get, update, and exact generation-target selection;
- provider templates, connections, routes, capability evidence, effective
  parameter specifications, and user overrides;
- schema-3 durable provider discovery, exact event-version-2 outbox polling,
  typed setup-assistant resume, and native credential compensation;
- durable model synchronization and bounded progress events;
- signed provider-catalog status, history, diff, import, and state-bound
  rollback;
- generation-preset CRUD, stored and candidate validation, and stored and
  candidate redacted request previews.

Fallible calls return status `0` on success. A non-empty `lorepia_buffer_t` is
owned by .NET through `NativeBuffer` and is released exactly once with
`lorepia_buffer_free`. A successful core pointer is owned by one
`SafeCoreHandle` and released exactly once with `lorepia_core_destroy`.

ABI version 7 event batches use exact chat event version `4` and include branch
and assistant-message routing, usage/cache details, and inert tool-call
proposal events. `CoreClient` rejects older and future event versions, requires
ABI version `7`, validates high-level inputs, uses strict
UTF-8 decoding, and maps native error JSON to `CoreInteropException`
properties: `Status`, `Code`, `Recoverable`, and `OperationId`.

The core configuration contains one absolute app-owned path:

```json
{"data_root":"%LOCALAPPDATA%\\LorePia"}
```

No credential is written into that configuration, provider contract JSON,
SQLite, logs, or event payloads.

This repository intentionally has no open-source license. Its source, C header,
and generated or compiled artifacts do not grant permission to copy,
redistribute, or relicense the project. Generated DLLs and `bin` or `obj`
output must not be committed.

All commands below run in PowerShell from the repository root unless a section
says otherwise.

## Prerequisites

- Windows 10 version 1809 or later.
- Visual Studio 2022 with .NET desktop development, Windows application
  development, MSBuild, and a Windows SDK.
- .NET 8 SDK 8.0.400 or a newer 8.0 feature band accepted by
  `apps/windows/global.json`.
- Rust 1.96.0, as pinned by the repository, with the MSVC target for the
  selected architecture.
- PowerShell 7 or Windows PowerShell 5.1.

Install the target or targets you intend to build:

```powershell
rustup target add x86_64-pc-windows-msvc
rustup target add aarch64-pc-windows-msvc
```

## Build Rust DLL

Build the C ABI DLL directly from the repository root:

```powershell
cargo build `
  --locked `
  --package lorepia-c-api `
  --target x86_64-pc-windows-msvc
```

For ARM64, replace the target with `aarch64-pc-windows-msvc`. Add `--release`
for a release build. Cargo writes the DLL to:

```text
target\<rust-target>\<debug-or-release>\lorepia_core.dll
```

The full app build in the following sections performs this step automatically
and first verifies that the Windows header mirror exactly matches the canonical
header.

## Restore .NET packages

Restore the actual Visual Studio solution for x64:

```powershell
dotnet restore apps/windows/Lorepia.sln --property:Platform=x64
```

Use `--property:Platform=ARM64` for ARM64. The repository contains
`Lorepia.sln`, not a `.slnx` solution.

## Run tests

Run the portable fake-ABI and app-logic suite:

```powershell
& .\apps\windows\scripts\test.ps1
```

The suite targets plain `net8.0`, so it can also run on macOS and Linux without
loading a native DLL. It source-links the actual shell view model,
observable-object base, and deterministic shell navigation model. Tests cover
shell success, in-flight, failure, and property-change states; every navigation
mapping; every high-level ABI operation; all chat event payload shapes;
stale/wrong-generation filtering; exact staging limits; strict UTF-8;
structured errors; disposal waiting for an in-flight call; PasswordVault
compensation and selection races; exact model/preset targeting; durable
model-sync review and two-job event isolation; discovery restart boundaries,
fresh-evidence policy restoration, exact compensation, old/future event
rejection; site-only setup defaults; signed-catalog exact-plan rollback;
effective parameter controls; credential-account continuity; candidate
validation; and leak-safe request previews.

The Windows app build runs this suite again with
`LOREPIA_RUN_LIVE_NATIVE_TESTS=1` and the exact newly built DLL. That live
vertical slice covers import, Library, chat, provider settings, and restart
persistence through the C ABI.

## Build WinUI app

Build and validate the x64 app on Windows:

```powershell
& .\apps\windows\scripts\build.ps1 `
  -Architecture x64 `
  -Configuration Debug
```

Build ARM64 release output:

```powershell
& .\apps\windows\scripts\build.ps1 `
  -Architecture arm64 `
  -Configuration Release
```

The script:

1. verifies the Windows C header mirror against the canonical header;
2. builds `lorepia-c-api` for the selected MSVC architecture;
3. restores packages and runs fake tests plus the live
   import/chat/settings/restart test against that exact DLL;
4. copies the DLL into application output through an explicit MSBuild
   property;
5. builds the WinUI application with MSBuild;
6. launches the unpackaged EXE with `--lorepia-ci-smoke`, waits at most
   30 seconds, and requires exit code `0` plus a `LOREPIA_CI_SMOKE_OK` marker.

The live smoke creates and activates the actual `MainWindow`, visits rendered
Library, Import Review, Chat, Settings, and Library pages, and fail-closes
unless each `Frame.CurrentSourcePageType`, page instance, shell state, and
selected navigation item agree. It also validates real core version and health
calls.

The repository wrapper selects the host architecture and runs a Release build:

```powershell
& .\scripts\build-windows.ps1
```

To use an already-built DLL:

```powershell
& .\apps\windows\scripts\build.ps1 `
  -Architecture x64 `
  -Configuration Debug `
  -NativeDllPath C:\absolute\path\to\lorepia_core.dll
```

## Run the app

The build script already executes the bounded CI launch smoke. For interactive
development, open the actual solution:

```powershell
Start-Process .\apps\windows\Lorepia.sln
```

In Visual Studio, choose the x64 or ARM64 platform that matches the DLL, set
`Lorepia.App` as the startup project, and run it. Alternatively, after the x64
Debug build above:

```powershell
Start-Process '.\apps\windows\Lorepia.App\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\Lorepia.App.exe'
```

Do not launch an output whose `lorepia_core.dll` is absent or for a different
architecture.

## Supported architectures

| App platform | Rust target | DLL output architecture |
|---|---|---|
| x64 | `x86_64-pc-windows-msvc` | x64 |
| ARM64 | `aarch64-pc-windows-msvc` | ARM64 |

The repository does not build or claim support for x86. The app platform and
DLL architecture must match.

## DLL placement

`Lorepia.Native` resolves the logical library name only from:

```text
<application output>\lorepia_core.dll
```

It does not search `PATH`, Cargo output, a developer directory, or another
installation. `build.ps1` supplies the exact absolute `LorepiaNativeDllPath`
MSBuild property and copies that file to the WinUI output. A missing DLL
produces an explicit error containing the expected absolute path.

## Directory layout

```text
Lorepia.App/          WinUI app, pages, view models, and Windows integration
Lorepia.Native/       P/Invoke boundary and high-level CoreClient
Lorepia.Native.Tests/ Portable contract, lifetime, and live DLL tests
include/              Checked-in mirror of the canonical C ABI header
scripts/build.ps1     Rust DLL, live test, WinUI build, and launch gate
scripts/test.ps1      Portable fake-ABI and app-logic test entry point
Lorepia.sln           Visual Studio solution
global.json           .NET 8 SDK selection policy
```

## Troubleshooting

### The app reports that the core is unavailable

Run `apps/windows/scripts/build.ps1` from the repository root and confirm the
logged DLL path and selected architecture. The loader deliberately refuses to
search for a fallback DLL.

### The Windows header differs from the canonical header

Regenerate or update the C ABI from its Rust binding source, then synchronize
`bindings/c-api/include/lorepia.h` and
`apps/windows/include/lorepia.h`. Do not patch only the Windows mirror or the
P/Invoke declarations.

### The ABI version is unsupported

Rebuild the Rust core, header, high-level .NET binding, and app from the same
revision. Do not bypass the ABI version check.

### `BadImageFormatException` appears

The DLL architecture does not match the selected x64 or ARM64 app platform.
Rebuild both for the same row in the supported-architecture table.

### WinUI restore or build fails

Confirm that the .NET 8 SDK selected by `global.json`, Visual Studio Windows
application tooling, MSBuild, and the Windows SDK are installed. The portable
test project can run off Windows, but the actual WinUI app build and launch
require a supported Windows host.

### PasswordVault access fails

Only the exact missing-entry HRESULT represents an absent credential. Other
PasswordVault or COM errors are real failures and must not be hidden or
replaced by plaintext credential storage.
