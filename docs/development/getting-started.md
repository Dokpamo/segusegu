# Getting started

Prerequisites for core development are Git and the pinned Rust toolchain.

```bash
./scripts/bootstrap.sh
cargo test --workspace --all-features --locked
```

Native applications additionally require their platform SDK. Android uses the
Android SDK/NDK and JDK, Apple uses the current Xcode toolchain, and Windows uses
Visual Studio with the Windows App SDK and .NET 8.

Start with `README.md`, then read the relevant app README and the architecture
documents before changing a cross-platform contract.
