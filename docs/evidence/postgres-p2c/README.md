# PostgreSQL P2c — official SOCI adoption and Shop retry evidence

Windows, PostgreSQL 18.6, Godot 4.7.2 and official SOCI v0.4.3 prerelease
`ae96333eaf765bace372fee993454f7870e79ffe`. GitHub's published asset digest matches
the downloaded ZIP SHA-256
`54ffd57acce47e4f18cab67d1b73414ce729dfac803eaa82bf0d02505127d94c`.
All 24 payload file hashes are pinned/verified; no locally rebuilt binary is used.
Fresh owned SCRAM loopback clusters and disposable SQLite only; clusters stopped.

Final native checks on the official payload:

- Shop settlement/retry `run-032dvgoj`: PASS including SQLite parity and existing
  multi-session settlement conflicts. Expanded fixture also passed `run-_gygujvf`.
  Server-injected custody/receipt `40001` and `40P01` fail once, roll back and then
  succeed; wallet/revenue/UID, original receipt and pending prefix match one commit.
- At most three total attempts for persistent retryable errors. Constraint, lock
  timeout, cancellation and generic error (even text containing 40001) run once.
  Rollback snapshots include wallet/item revisions, custody, offers/cells and receipts.
- Independent editor queued before buyer retry changes offer price/revision after
  rollback. Purchase reselects and returns stale without spending. This diagnostic
  alone uses larger native-session synchronization timeouts, not capacity gates.
- COMMIT errors with the same retryable codes still stop after one attempt, close
  the native connection and return unknown. Reopen finds no receipt/state changes.
  Killing the connection between statement abort and rollback also runs once;
  failed cleanup never permits retry. No blind compensation or fresh command ID.
- Revenue collection redoes the whole headroom/pending/revenue operation, applies
  income once, records one result and replays it without another mutation.
- Native COMMIT lifecycle/structured errors `run-6afn4hwa`, readiness
  `run-l5eb7wtw`, Wallet `run-81z0djh_`, Exchange orders `run-jfi_rqe7` and
  Inventory concurrency `run-gc9o7hfn`: PASS.

Production SQLite regression checks: isolated async Auction lifecycle, Marketplace
crash/backup/recovery, two-client market_network and default smoke PASS. These
remain SQLite clients, not PostgreSQL World/CEF integration. Recovery's existing
small durability observation is not a new performance/load benchmark.

No Linux or template_release runtime test, contention capacity, soak, P3 execution/
fencing or cutover claim. Other domain stores and unreceipted checkpoints have no
automatic retry policy. Raw diagnostics/metadata remain ignored in
`.godot/verification/`; player/runtime stores and pre-existing user files are preserved.
