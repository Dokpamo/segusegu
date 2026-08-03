# Windows development

The production Windows client is built from the Tauri mainline under
`apps/lorepia`; new product features are implemented there. A complete Windows
result requires a Tauri Windows x64 build and launch smoke on a Windows host,
plus any separately required ARM64 compile validation. A frontend-only build is
insufficient.

## Tauri development target

The current hosted job uses:

- the x64 `windows-2022` runner;
- Node `24.18.1` from `.node-version`;
- Rust `1.96.0` and the host MSVC target; and
- the Visual Studio/MSVC, Windows SDK, and WebView2 tooling supplied by that
  runner image.

The workflow does not pin the hosted image's Visual Studio, Windows SDK, or
WebView2 patch version. Record them when reporting a local or CI result.

Tauri reads `tauri.conf.json` and `tauri.windows.conf.json`, then CI applies
these development overlays in order:

1. `src-tauri/tauri.dev.conf.json`;
2. `src-tauri/tauri.windows.dev.conf.json`.

The configured development identifier is `dev.lorepia.windows.dev` and the
product name is `LorePia Dev`.

From the repository root, the CI-equivalent unsigned, unbundled build and
process smoke are:

```powershell
Set-Location apps/lorepia
npm ci --ignore-scripts
node ..\..\scripts\check-npm-licenses.mjs
npm run tauri -- build --debug --no-bundle --ci `
  --config src-tauri/tauri.dev.conf.json `
  --config src-tauri/tauri.windows.dev.conf.json

$LorepiaProcess = Start-Process `
  -FilePath ..\..\target\debug\lorepia.exe `
  -PassThru
Start-Sleep -Seconds 10
if ($LorepiaProcess.HasExited) {
  throw "Windows Tauri process exited during launch smoke"
}
Stop-Process -Id $LorepiaProcess.Id
```

The hosted smoke also checks generated Tauri permission drift. Because this is
a `--no-bundle` process check, it does not establish an installed package
identity, installer/updater key, signing lineage, PasswordVault continuity, or
unpackaged-native-to-Tauri upgrade behavior. The source production identifier
`dev.lorepia.windows` is configured, but those release facts remain separate
blocked decisions and tests.

The current hosted workflow does not perform Windows ARM64 compile validation.
If a change requires it, record it as a separate executed check or as not run;
do not infer it from the x64 result.

These commands are configured CI instructions, not a claim that the current
checkout has passed a Windows build or launch.

## Frozen native harness

The WinUI project under `apps/windows` is frozen as a compatibility,
behavioral-reference, and old-to-new upgrade-test harness. See its README for
prerequisites. It may receive only parity, continuity, security, or
build-maintenance changes until the native removal gates pass.

```powershell
./scripts/build-windows.ps1
```

This retained command does not build or validate the Tauri Windows client.
