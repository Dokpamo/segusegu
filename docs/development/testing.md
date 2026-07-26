# Testing

The repository uses four layers:

1. Rust unit tests for parsing, path policy, prompt order, events, repositories,
   providers, and ownership;
2. Rust vertical tests for import, persistence, restart, and generation;
3. binding contract tests for version, health, UTF-8, error, and lifetime;
4. native ViewModel and navigation tests using a fake `CoreClient`, plus a live
   binding smoke test on supported CI hosts.

Synthetic hostile archives live in `testdata/`. Regenerate them with
`cargo xtask testdata regenerate`. A test must never require user data or a live
model credential.

Performance scenarios are recorded before setting pass/fail budgets: 1,000
characters, 100,000 message metadata rows, large imports, long streams, rapid
cancellation, and restart recovery.
