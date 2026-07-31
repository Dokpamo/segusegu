# LorePia for Windows

## Overview

The Windows client is a native WinUI 3 application over the Rust C ABI:

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
selection. It loads persisted messages, provider profiles, and app settings
through `CoreClient`.

Send retrieves the selected provider's secret from Windows PasswordVault,
passes it only for that generation call, and then polls bounded event batches.
Only the exact missing-entry HRESULT is treated as an absent optional
credential; other PasswordVault or COM failures are surfaced. The view model
accepts events only when the conversation ID and generation ID match and the
sequence is strictly increasing. A dropped-event count triggers a persisted
message refresh. Commit, finish, failure, and cancellation also refresh
persisted messages. A pending assistant generation is resumed after navigation
or restart and can be cancelled explicitly.

### Provider settings

Provider profile metadata is owned by Rust storage. The API credential is not
included in that profile and is stored only in Windows PasswordVault under the
profile ID. A blank credential field preserves the existing secret; users can
remove it explicitly. Settings also choose the default provider and whether a
failed or cancelled partial assistant response is preserved.

### C ABI contract

`bindings/c-api/include/lorepia.h` at the repository root is the source of
truth. `apps/windows/include/lorepia.h` is its checked-in mirror. ABI version 3
covers:

- core create, destroy, version, health, and structured last error;
- inspect, commit, and discard import plus character get and list;
- conversation open and list plus message list;
- send, cancel, and bounded event polling;
- app settings get and update;
- provider profile list, upsert, and delete.

Fallible calls return status `0` on success. A non-empty `lorepia_buffer_t` is
owned by .NET through `NativeBuffer` and is released exactly once with
`lorepia_buffer_free`. A successful core pointer is owned by one
`SafeCoreHandle` and released exactly once with `lorepia_core_destroy`.

ABI version 3 is the first revision whose event batches may contain event
schema version 2 branch and assistant-message routing metadata. `CoreClient`
requires ABI version `3`, validates high-level inputs, uses strict
UTF-8 decoding, and maps native error JSON to `CoreInteropException`
properties: `Status`, `Code`, `Recoverable`, and `OperationId`.

The core configuration contains one absolute app-owned path:

```json
{"data_root":"%LOCALAPPDATA%\\LorePia"}
```

No credential is written into that configuration, provider profile JSON,
SQLite, or logs.

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
structured errors; and disposal waiting for an in-flight call.

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
