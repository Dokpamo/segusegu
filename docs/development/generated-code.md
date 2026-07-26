# Generated code

The UniFFI Rust API is the source of truth.

```bash
./scripts/generate-bindings.sh kotlin
./scripts/generate-bindings.sh swift
```

Generated Kotlin and Swift files carry no product logic and are not edited by
hand. The generator version is locked in `Cargo.lock`; `.gitattributes` fixes
line endings. CI regenerates sources, verifies an explicit file manifest, and
fails on tracked changes, untracked additions, or stale extra files with
`scripts/check-generated-tree.sh`.

`apps/apple/project.yml` is also regenerated in Apple CI with XcodeGen 2.45.4
from its checksum-verified release archive. The committed Xcode project and
shared schemes must remain an exact result of that specification.

Native libraries, DLLs, `.so` files, static libraries, XCFrameworks, APKs, and
app packages are build outputs and are ignored.
