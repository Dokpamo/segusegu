# Dependency rules

The Rust dependency graph is acyclic:

```text
domain
├── content
├── storage
└── providers
    └── chat (also depends on domain)

content + storage + providers + chat + domain
└── core
    ├── bindings/uniffi
    └── bindings/c-api
```

- `domain` contains serializable meaning and no I/O implementation.
- `content` reads untrusted packages but never writes application state.
- `storage` owns SQLite and the local file layout.
- `providers` owns network protocol differences and no prompt policy.
- `chat` owns prompt and generation-event semantics.
- `core` coordinates high-level use cases.
- bindings translate types, errors, ownership, and calls only.
- native apps call a `CoreClient`; they do not parse packages or open SQLite.
