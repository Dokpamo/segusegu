# Generated code

The UniFFI Rust API is the source of truth.

```bash
./scripts/generate-bindings.sh kotlin
./scripts/generate-bindings.sh swift
```

Generated Kotlin and Swift files carry no product logic and are not edited by
hand. The generator version is locked in `Cargo.lock`; `.gitattributes` fixes
line endings. CI regenerates sources and checks for a clean diff.

Native libraries, DLLs, `.so` files, static libraries, XCFrameworks, APKs, and
app packages are build outputs and are ignored.
