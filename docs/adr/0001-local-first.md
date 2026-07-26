# ADR 0001: Local-first product

## Decision

Store characters, conversations, messages, settings, and source packages on the
device. Do not add an operated backend, account, cloud sync, billing, or
marketplace to the initial product.

## Consequences

The app works without an account and keeps user state under an OS-owned data
root. Backup and multi-device sync are not provided. Model traffic occurs only
when the user configures a direct endpoint.
