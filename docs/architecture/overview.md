# Architecture overview

LorePia is a local-first application with four native executables and one shared
Rust application core.

```text
Native UI
  -> platform CoreClient
  -> UniFFI or C ABI
  -> lorepia-core use case
  -> content / storage / chat / providers
  -> versioned core event
  -> native state and UI
```

The core is deliberately UI-free. It enforces import safety, persistent data
semantics, prompt order, generation identity, event ordering, cancellation, and
provider-neutral errors. Native code owns interaction and every OS capability.

The initial product has no developer-operated backend. SQLite, immutable source
packages, and content-addressed assets live under the app's OS-provided data
directory. Credentials stay in the OS credential store.
