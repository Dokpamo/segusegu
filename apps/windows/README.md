# LorePia for Windows

## Overview

This folder contains the native Windows application frame:

- `Lorepia.App`: C#/.NET 8 and WinUI 3 UI, navigation, file selection, staging,
  and Windows lifecycle;
- `Lorepia.Native`: the safe high-level .NET binding over the Rust C ABI;
- `Lorepia.Native.Tests`: cross-platform mapping, ABI-shape, buffer, and handle
  lifetime tests.

The application currently exposes Library, Import review, Chat, and Settings
screens. The shipped frame ABI supports core creation, version display, health
diagnostics, and the real local character list. Import approval and chat
generation stay disabled until their high-level Rust ABI operations exist; the
Windows UI does not implement those product rules independently.

## Prerequisites

- Windows 10 version 1809 or later;
- Visual Studio 2022 with .NET desktop development and Windows application
  development tooling;
- .NET 8 SDK 8.0.400 or newer in the 8.0 feature band;
- Rust with the MSVC target for the selected architecture;
- PowerShell 7 or Windows PowerShell 5.1.

Install the Rust target needed by the build:

```powershell
rustup target add x86_64-pc-windows-msvc
rustup target add aarch64-pc-windows-msvc
```

## C ABI contract

The root `bindings/c-api/include/lorepia.h` is the single source of truth.
`include/lorepia.h` is its checked-in Windows mirror. ABI version 1 contains:

```c
uint32_t lorepia_abi_version(void);
int32_t lorepia_core_create(
    const uint8_t* config_json,
    size_t config_json_len,
    lorepia_core** out_core);
void lorepia_core_destroy(lorepia_core* core);
int32_t lorepia_core_version(
    const lorepia_core* core,
    lorepia_buffer* out_buffer);
int32_t lorepia_core_health_check_json(
    const lorepia_core* core,
    lorepia_buffer* out_buffer);
int32_t lorepia_core_list_characters_json(
    const lorepia_core* core,
    lorepia_buffer* out_buffer);
void lorepia_buffer_free(lorepia_buffer buffer);
```

Fallible calls return status `0` on success and write their result through the
out parameter. `lorepia_buffer` is a UTF-8 byte pointer plus byte length. Rust
owns every returned buffer until .NET calls `lorepia_buffer_free`. .NET owns a
successful core handle until `SafeCoreHandle` calls `lorepia_core_destroy`.

`CoreClient.Open(dataRoot)` requires an absolute app-owned path and serializes:

```json
{"data_root":"<absolute Windows LocalApplicationData/LorePia path>"}
```

The app creates and uses `%LOCALAPPDATA%\LorePia`.

The health JSON maps these fields:

```text
core_version
database_open
schema_version
data_root_writable
staging_writable
recovery_pending
active_jobs
```

`CoreClient` rejects any ABI version other than `1`.

Character-list JSON is a top-level array. The binding maps `id`, `name`,
`description`, and `source_hash`, while allowing future unknown fields such as
avatar metadata.

## Restore and run binding tests

```powershell
dotnet restore Lorepia.Native.Tests/Lorepia.Native.Tests.csproj
dotnet test Lorepia.Native.Tests/Lorepia.Native.Tests.csproj
```

The binding and tests target plain `net8.0`, so the same command can run on
macOS or Linux without loading a native DLL. Tests inject a fake ABI and do not
call a user-installed library.

## Build the Rust DLL and WinUI app

From this directory on Windows:

```powershell
./scripts/build.ps1 -Architecture x64 -Configuration Debug
```

For arm64:

```powershell
./scripts/build.ps1 -Architecture arm64 -Configuration Release
```

The script:

1. builds the `lorepia-c-api` Cargo package for the exact Windows target;
2. prints and validates the exact `lorepia_core.dll` path;
3. restores .NET dependencies and runs fake contract tests plus a live
   `core_create`/version/health/list smoke test against that DLL;
4. copies that DLL into the WinUI output through an explicit MSBuild property;
5. builds the WinUI app.

To use a DLL produced by a separate build:

```powershell
./scripts/build.ps1 `
  -Architecture x64 `
  -NativeDllPath C:\absolute\path\to\lorepia_core.dll
```

Open `Lorepia.sln` in Visual Studio, select the matching x64 or ARM64 platform,
set `Lorepia.App` as the startup project, and run it after the native DLL has
been copied by the build script.

## DLL placement

`Lorepia.Native` registers a resolver for the logical name `lorepia_core` and
loads only:

```text
<application output>/lorepia_core.dll
```

It does not scan `PATH`, Cargo output, a developer folder, or another installed
application. A missing output DLL produces an explicit error containing the
expected absolute path.

## Supported architectures

| .NET platform | Rust target |
|---|---|
| x64 | `x86_64-pc-windows-msvc` |
| ARM64 | `aarch64-pc-windows-msvc` |

The DLL architecture must match the application platform.

## Directory layout

```text
Lorepia.App/          WinUI application and view models
Lorepia.Native/       P/Invoke boundary and high-level CoreClient
Lorepia.Native.Tests/ Binding and lifetime tests
include/              C ABI contract
scripts/              Deterministic Windows build and test entry points
Lorepia.sln           Visual Studio solution
```

## Troubleshooting

### The app reports that the core is unavailable

Run `scripts/build.ps1` and confirm the logged DLL path and selected
architecture. The app deliberately refuses to search for a fallback DLL.

### ABI version is unsupported

Rebuild the Rust core and .NET app from the same revision. Do not bypass the ABI
check.

### `BadImageFormatException`

The DLL architecture does not match the selected x64 or ARM64 platform.

### WinUI restore or build fails

Confirm that the .NET 8 SDK, Visual Studio Windows application tooling, and the
Windows SDK are installed. Then run:

```powershell
dotnet restore Lorepia.sln
dotnet build Lorepia.App/Lorepia.App.csproj -p:Platform=x64
```
