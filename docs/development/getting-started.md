# Getting started

Prerequisites for Core development are Git and the pinned Rust toolchain.

```bash
./scripts/bootstrap.sh
cargo test --workspace --all-features --locked
```

The production-client mainline is the Tauri application under `apps/lorepia`.
It requires Node `24.18.1`, pinned in [`.node-version`](../../.node-version),
and Rust `1.96.0`, pinned in
[`rust-toolchain.toml`](../../rust-toolchain.toml). All frontend packages are
installed from the committed `package-lock.json`.

```bash
./scripts/check-tauri.sh
```

That command installs the locked frontend graph and runs the configured format,
lint, TypeScript/Svelte, test, and production-build checks. A frontend build is
not a substitute for a Tauri platform build or launch smoke.

Every ordinary development build uses `LorePia Dev`, the
`main-development` capability, and a platform identity isolated from
production. Tauri reads `tauri.conf.json` and the matching automatic
`tauri.<platform>.conf.json`, then the CI-equivalent commands merge these two
explicit files in order:

1. `src-tauri/tauri.dev.conf.json`; and
2. `src-tauri/tauri.<platform>.dev.conf.json`.

Do not omit or reverse that pair. The configured development identities are:

| Platform | Development identity | CI-equivalent guide |
|---|---|---|
| Android | `dev.lorepia.app.dev` | [Android development](android.md) |
| iOS | `dev.lorepia.ios.dev` | [Apple development](apple.md) |
| macOS | `dev.lorepia.mac.dev` | [Apple development](apple.md) |
| Windows | `dev.lorepia.windows.dev` | [Windows development](windows.md) |

Tauri platform work also needs the matching host and SDK. The platform guides
record the same Node, Rust target, JDK/SDK/NDK, Xcode, Visual Studio, command,
identity assertion, install, and launch shape as
[the Tauri workflow](../../.github/workflows/tauri.yml). Merely documenting a
command does not mean it passed locally.

Production-identity upgrade tests additionally require authorized signing
assets and a disposable device, simulator, emulator, or VM. If those assets or
a matching host are unavailable, report the check as not run instead of
treating it as passed. Do not use a production identity for ordinary local
development.

The native projects under `apps/android`, `apps/apple`, and `apps/windows` are
frozen compatibility and upgrade-test harnesses. Their prerequisites remain
documented in their READMEs, but new product features are not implemented
there.

Start with `README.md`, the
[Accepted Tauri ADR](../architecture/decisions/ADR-0006-adopt-tauri-primary-client.md),
and the architecture documents before changing a cross-platform contract.
