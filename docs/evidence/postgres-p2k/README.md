# PostgreSQL P2k — Account claim retry evidence

Verified on 2026-10-18: Windows, Godot 4.7.2, PostgreSQL 18.6 and official pinned
SOCI v0.4.3. Native suites use fresh owned SCRAM loopback clusters, stopped after
verification. No dependency pin, schema, public protocol or runtime backend change.

- Expanded claims suite `run-oqn18hkj`: PASS, retaining SQLite parity, two-alt
  claim conflicts, footprint conflicts, provenance constraints, bounded private
  projections, coherent visitor snapshots, int64 revisions and recovery.
- Server-injected statement `40001`/`40P01` at item update, custody transfer and
  receipt insertion succeeds on the second complete attempt for explicit and
  automatic receiving, including upgraded swords and material stacks. One
  UID/custody, receiving owner, item revision, amount, upgrade and exact original
  affixes/sockets survive. Claim custody is removed atomically.
- Original receiver replays the exact result without a new commit, including
  after reopening the native connection. Another alt with that command ID
  conflicts; account-scoped discovery still returns the original outcome.
- Persistent retryable errors stop after three total attempts; constraint,
  lock-timeout and cancellation errors run once. All mutations/receipts roll
  back. The original exhausted command ID remains usable after recovery.
- Deferred COMMIT `40001`/`40P01` runs once, closes and returns `outcome_unknown`.
  Reopen/discovery verifies the fixture's aborted state, not the outcome of
  arbitrary lost COMMIT replies. No automatic retry crosses this boundary.
- Independently queued sessions receive the same claim or occupy a nonstarting
  destination cell before retry. The older operation observes owner/occupied
  rejection, or reselects automatic Inventory placement. Receiver stays fixed.
  Only these barrier workers extend their session-local diagnostic timeouts.
- Exchange ledger `run-xdevxhli` and Inventory concurrency `run-exgri1_5`: PASS,
  including caller-owned claim production and shared receiving boundaries.
- Default smoke: 14 Godot checks and 85 Web contracts PASS. Pinned native SOCI
  payload verification and `git diff --check`: PASS.

No PostgreSQL World/CEF integration, physical-input, Linux or throughput/soak
claim. The existing claim producer remains owned by its caller's transaction.
Starter/pickup and unreceipted checkpoints retain their policies; broader P2
acceptance, P3 nonblocking execution/fencing and P4 remain open. Production stays
SQLite. Raw diagnostics remain ignored under `.godot/verification`.
