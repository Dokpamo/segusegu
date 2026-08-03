# Frozen Windows compatibility rules

- This directory is the frozen native Windows compatibility, reference, and
  upgrade-test harness retained during the Tauri mainline migration.
- Do not add new product features here. Changes are limited to parity evidence,
  upgrade and data/credential continuity, security regressions, and maintenance
  required to keep the native baseline buildable until its removal gates pass.
- The production-client mainline lives under `apps/lorepia`. Do not implement
  Tauri frontend or plugin code in this directory.
- Keep the retained WinUI screens, navigation, view models, window state, file
  pickers, credential storage, and Windows lifecycle code in `Lorepia.App`.
- Keep every P/Invoke declaration, C ABI DTO, native-buffer release, handle
  lifetime, and native error mapping in `Lorepia.Native`.
- `Lorepia.App` calls only the public high-level `CoreClient`; it must never call
  `NativeMethods`, expose native pointers, access SQLite, or inspect content
  packages.
- Use `SafeCoreHandle` for every owned core pointer and `NativeBuffer` for every
  owned buffer returned by Rust.
- Treat the root `bindings/c-api/include/lorepia.h` as the single source of
  truth. Keep the Windows mirror in `include/lorepia.h`, P/Invoke declarations,
  and contract tests synchronized with it.
- Load `lorepia_core.dll` only from `AppContext.BaseDirectory`. Never search a
  developer machine for a fallback DLL.
- Never commit generated native binaries or `bin`/`obj` output.
- For binding-only changes, run:

  ```powershell
  ./scripts/test.ps1
  ```

- For a runnable x64 or arm64 app, run:

  ```powershell
  ./scripts/build.ps1 -Architecture x64
  ./scripts/build.ps1 -Architecture arm64
  ```

- A Windows change is complete only when relevant .NET tests pass and the WinUI
  app builds on a supported Windows host. Report Windows-only checks that were
  not executed.
- A passing native build is baseline evidence only; it does not prove Tauri
  parity, production upgrade continuity, or release readiness.
