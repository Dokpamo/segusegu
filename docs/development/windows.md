# Windows development

See `apps/windows/README.md`.

The WinUI application consumes `Lorepia.Native`, which is the only project
allowed to declare P/Invoke. The build script compiles the Rust DLL for the host
architecture and places the exact artifact under the app runtime directory.

```powershell
./scripts/build-windows.ps1
```
