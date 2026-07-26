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

Performance measurements intentionally have no pass/fail duration threshold.
Run the ignored suite explicitly and retain its printed timings when comparing
revisions:

```bash
cargo test -p lorepia-core --test performance_scenarios -- --ignored --nocapture
```

Every scenario uses temporary, project-owned synthetic data. It requires no
external network, credential, user content, or repository fixture:

- reopen and list a 1,000-character library;
- persist and load 100,000 message metadata rows;
- inspect a CHARX package with a 32 MiB asset;
- inspect and enumerate a CHARX package containing 2,000 assets;
- process 4,096 ordered streaming chunks;
- run 100 consecutive cancellation and regeneration cycles;
- reopen persisted library and conversation data while recovering abandoned
  staging work.

The suite prints elapsed times and workload counts but makes only functional
assertions. Establish a regression threshold only after comparable measurements
show a stable baseline.
