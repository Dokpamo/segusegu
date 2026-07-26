# ADR 0001: Local-first product

## Context

Characters and conversations are private user data, and the initial product
does not require an operated service to deliver its core value.

## Decision

Store characters, conversations, messages, settings, and source packages on the
device. Do not add an operated backend, account, cloud sync, billing, or
marketplace to the initial product.

## Alternatives considered

- Require an account and backend for all state: rejected because it adds an
  unnecessary trust, availability, and operations dependency.
- Treat cloud sync as an initial requirement: deferred until its encryption,
  conflict, and consent model has a concrete product need.

## Consequences

The app works without an account and keeps user state under an OS-owned data
root. Backup and multi-device sync are not provided. Model traffic occurs only
when the user configures a direct endpoint.
