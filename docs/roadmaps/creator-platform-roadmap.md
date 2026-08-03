# Creator platform roadmap

- Status: Roadmap, not an implementation approval
- Relationship to Tauri migration: Separate; not a release or migration
  completion gate

## Intent

Lorepia should eventually let creators compose interactive character and room
experiences without weakening the local-first Core, import trust boundary, or
platform security model. The first supported format is declarative and
Rust-validated. Arbitrary script execution is not approved.

This document does not authorize an unused Creator crate, frontend directory,
placeholder API, package flag, or fake renderer. Code is added only when a
phase has an approved contract and a real tested product slice.

## Fixed boundaries

Creator content does not:

- receive Tauri capabilities or invoke Tauri IPC;
- access the filesystem, credential store, clipboard, shell, or native APIs;
- open SQLite or depend on internal Core paths;
- call external networks;
- load remote HTML or JavaScript;
- bypass content-package inspection, review, or explicit commit;
- receive private prompt bodies, API credentials, or provider headers; or
- change Core conversation and branch semantics from presentation code.

Tauri Isolation and an iframe without capabilities are not treated as a CPU,
memory, storage, or store-policy sandbox for hostile script.

## Phase 1: `declarative-v1`

Define a versioned, data-only experience manifest with:

- a standard component schema;
- explicit layout and responsive constraints;
- typed text, image, choice, status, and bounded decorative components;
- semantic label, description, role, reading order, and focus metadata;
- project-owned theme tokens rather than arbitrary CSS;
- static package asset references by logical asset identifier;
- declared actions from a closed allowlist; and
- explicit schema and renderer compatibility versions.

Rust parses and validates the manifest during content inspection. It rejects
unknown executable fields, unbounded collections, invalid references, unsafe
URLs, inaccessible required controls, and incompatible versions before commit.

The renderer consumes a safe projection; it does not parse the original package
or infer permissions.

### Room-state projection

Core owns a versioned room-state model and derives a bounded projection for the
renderer. The projection:

- contains only fields declared by the package and allowed by the schema;
- is validated in Rust before every publication;
- uses stable logical identifiers rather than database keys or file paths;
- carries no credential, provider request, private prompt, or internal error;
- is size, depth, string-length, collection-count, and update-rate bounded; and
- is reconciled from persisted Core state after restart or dropped delivery.

Renderer actions return a closed, typed intent to Rust. Only Core decides
whether an intent is valid and how it changes product state.

### Phase 1 gate

- schema, projection, and action semantics have an Accepted ADR;
- parser limits and negative fixtures exist;
- import review describes every requested visual or interaction surface;
- rendering passes keyboard, screen-reader, text-scaling, reduced-motion, and
  contrast tests;
- malicious packages cannot create script, network, filesystem, credential, or
  native capability; and
- version upgrade and unsupported-version behavior are deterministic.

## Phase 2: visual Creator Studio

Build a local visual editor for `declarative-v1` only after the runtime contract
is stable. Studio uses the same schema, validator, preview renderer, and package
inspection path as imported content.

Planned capabilities:

- component palette constrained to the standard schema;
- property editing with schema-derived validation;
- responsive phone, tablet, and desktop previews;
- semantic reading-order and focus-order inspection;
- theme-token and static-asset selection;
- room-state fixture preview;
- validation, warning, and blocked-reason panels; and
- deterministic export of a reviewable package.

Studio is a product feature, not a general web IDE. It does not add a code
editor, arbitrary CSS/JavaScript execution, remote package installation, or a
plugin marketplace.

### Phase 2 gate

- the exported package round-trips through normal Rust inspection and commit;
- preview and runtime use the same renderer contract;
- undo/redo and autosave are crash-safe and local;
- exports contain no workstation path, secret, private conversation, or
  unreferenced local asset; and
- the Studio itself meets platform accessibility and input requirements.

## Phase 3: `html-static-v1` research

Static HTML-like presentation is a separate security design, not an automatic
extension of `declarative-v1`. Before implementation, a focused proposal must
define:

- an allowed element and attribute set;
- deterministic sanitization owned by Rust;
- CSS and URL policy;
- local asset resolution through opaque identifiers;
- CSP and navigation behavior;
- form and input restrictions;
- accessibility requirements;
- memory, DOM, image, and layout limits;
- package signature and review presentation; and
- store-policy treatment on every supported platform.

The default is no scripts, no event-handler attributes, no remote resources,
no forms that transmit data, no browser storage, and no external navigation.
Research output does not create a runtime flag or placeholder renderer.

## `script-v1`: independent decision required

`script-v1` is not on the approved implementation path. Considering it requires
all of the following before any executable package is built:

1. an independent threat model covering capability escape, denial of service,
   covert storage, data inference, prompt or credential exposure, and update
   abuse;
2. an enforceable CPU, memory, wall-time, recursion, allocation, output,
   persistence, and message-rate budget;
3. a deterministic host API with no ambient authority;
4. cryptographic package provenance, revocation, compatibility, and incident
   response design;
5. an Apple and Google store-policy review plus Windows and macOS distribution
   review;
6. fuzzing, adversarial fixtures, containment tests, and kill-switch behavior;
7. a clear user consent and review model; and
8. a new Accepted ADR and explicit implementation authorization.

An iframe with no declared capability and Tauri's Isolation Pattern do not
satisfy these requirements. Until the independent decision is accepted,
downloaded or package-supplied JavaScript, remote HTML, network-enabled Creator
content, filesystem access, native access, and Creator Tauri IPC remain
forbidden.

## Delivery order

```text
declarative schema ADR
  -> Rust validator and safe projection
  -> accessible runtime renderer
  -> import and upgrade fixtures
  -> visual Studio
  -> html-static security proposal, if still needed
  -> independent script RFC/ADR, if ever justified
```

Each arrow is a review gate. Creator work does not delay Tauri mainline release,
and Tauri migration does not pre-approve a later Creator runtime.
