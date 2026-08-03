# Dependency rules

The production-client call graph is:

```text
Svelte / TypeScript frontend
  -> allowlisted typed Tauri commands and ordered Channels
  -> apps/lorepia/src-tauri
  -> shell-api
  -> lorepia-core
  -> content / storage / chat / providers / domain

apps/lorepia/src-tauri
  -> first-party lorepia-platform plugin
  -> OS credential store / picker / lifecycle / other native services
```

The frontend owns shared presentation, navigation, semantic accessibility
markup, and cross-platform interaction state. It does not import Rust internals,
open SQLite, parse content packages, perform provider networking, receive stored
credential material, or receive unrestricted absolute paths.

`shell-api` is the Tauri-safe adapter. It validates command input, converts
current Core results to bounded UI projections, redacts internal fields, maps
stable errors, and bridges current Core events to ordered Channels. It contains
no product-domain logic and does not silently redesign current Core semantics.

`apps/lorepia/src-tauri` composes `shell-api` with the first-party platform
plugin. It owns the narrow picker/vault coordination and in-process
compensation choreography required by a Tauri command; neither dependency calls
the other.

The platform plugin owns OS credential storage, file picking and bounded
transport, lifecycle, notifications, deep links, menus, and other native
services. It gives the frontend only safe state or opaque identifiers. Provider
networking and content-package parsing remain in Rust.

The Rust dependency graph remains acyclic:

```text
domain
├── content
├── storage
└── providers
    └── chat (also depends on domain)

content + storage + providers + chat + domain
└── core
    ├── shell-api
    │   └── apps/lorepia/src-tauri
    ├── bindings/uniffi  (frozen native compatibility only)
    └── bindings/c-api   (frozen native compatibility only)
```

- `domain` contains serializable meaning and no I/O implementation.
- `content` reads untrusted packages but never writes application state.
- `storage` owns SQLite and the local file layout.
- `providers` owns network protocol differences and no prompt policy.
- `chat` owns prompt and generation-event semantics.
- `core` coordinates high-level use cases.
- `shell-api` translates and protects the Tauri boundary only.
- bindings translate types, errors, ownership, and calls only while retained for
  the frozen native compatibility harnesses.
- no adapter, binding, frontend, or platform plugin contains product rules that
  belong in Core.
- new product features are implemented through the Tauri mainline. The frozen
  native applications receive only parity, upgrade, security, or build
  maintenance changes until their removal gates pass.
