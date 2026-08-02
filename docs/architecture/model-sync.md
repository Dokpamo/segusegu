# Durable provider model synchronization

Provider model listing is a review-gated durable job. Native applications call
the high-level Core API and never write provider catalog rows directly.

The public flow is:

1. `start_provider_model_sync(connection_id, credential)` creates a durable
   `created` job before network I/O. The credential is moved only into the live
   request task.
2. Core advances the job to `fetching`, lists models, rejects any normalized
   field which reflects the credential, and stores a canonical diff.
3. The job becomes `diff-ready-awaiting-review`. Native UI presents the diff
   and passes its SHA-256 digest to `approve_provider_model_sync`.
4. Core recomputes the digest, performs revision and provider-graph compare-and-
   swap checks, and atomically applies routes, presets, capability observations,
   connection status, terminal job state, and the terminal outbox event.

`get_provider_model_sync` reads a job by ID.
`list_provider_model_syncs` lists one connection's jobs newest-first so work can
be rediscovered after process restart. `cancel_provider_model_sync` durably
cancels pre-commit work. `poll_provider_model_sync_events(job_id, limit)`
returns versioned, redacted events for exactly one job with at-least-once
delivery. The host acknowledges each processed `(job_id, sequence)` with
`ack_provider_model_sync_event`; until then, polling returns it again. Polling
one job therefore cannot consume another job's events. A global drain is not
exposed, so filtering a cross-job result cannot consume another job's events.

The durable states are `created`, `fetching`, `interrupted`,
`diff-ready-awaiting-review`, `committing`, `completed`, `failed`, and
`cancelled`. Opening storage converts abandoned `created`, `fetching`, or
`committing` jobs to `interrupted` and emits an event. It never restarts a
credential-bearing network request. A stored review remains reviewable after
restart.

Provider connection archive is rejected while any job for that connection is
nonterminal, including `interrupted` and review-ready work. Native UI can
therefore rediscover the job through the still-visible connection, then finish
or cancel it before retrying removal. Completed, failed, and cancelled history
is retained but does not block archive.

The old synchronous `refresh_provider_models` API is deprecated and always
rejects the call. This prevents compatibility callers from bypassing review.

## Route lifecycle

A route ID has immutable connection, API-family, provider-model, and route
configuration identity. Provider listings cannot rename an existing route.

When a route is seen, synchronization resets `miss_count`, updates bounded
normalized metadata, records the metadata-producing job, and advances
`last_seen_at`. When a route is omitted, synchronization increments
`miss_count` once, records only the checking job, and preserves positive
metadata and `last_seen_at`. Explicit `documented_only`, `access_denied`,
`deprecated`, and `retired` states are not replaced by a temporary-missing
state. Existing presets and generation references are retained.

The persisted "raw metadata" field is not a provider response body. Core
reconstructs a bounded object containing only token limits and supported
generation method names.

## Secret and concurrency boundaries

Credentials cannot be represented by the job, review, result, failure, route,
or event types. Failures persist only a stable error code, a fixed localization
key, and a recoverability flag.

Every state transition uses a state-and-revision compare-and-swap. A connection
may have only one active synchronization. The job also captures a canonical
hash of the connection, routes, presets, and capability observations; approval
fails if another writer changes that graph. SQLite transaction rollback ensures
that an apply failure leaves the complete pre-approval graph intact.
