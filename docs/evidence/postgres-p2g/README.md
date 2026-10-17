# PostgreSQL P2g — NPC purchase retry evidence

Windows, Godot 4.7.2, PostgreSQL 18.6 and the official pinned SOCI v0.4.3 payload.
Fresh owned SCRAM loopback clusters and disposable SQLite only; owned clusters
stopped after verification. Dependency pin, schema and runtime remain unchanged.

- NPC purchase `run-371xcr8e`: PASS, retaining SQLite parity, pending/reserved
  funds, full-footprint placement, original receipt/reopen recovery, exact-target
  replay with occupied placement, int64 watermarks and custody integrity checks.
- Server-injected statement SQLSTATE `40001`/`40P01` at pending-income application,
  spend, item creation, custody creation and receipt persistence each succeed on
  the second full attempt for both a sword and a material stack. One durable UID,
  one debit, one pending prefix, original quantity/placement and exact replay pass.
- Persistent retryable faults stop after three total attempts. Constraint,
  lock-timeout and cancellation codes run once. Failed attempts preserve item,
  custody, account-item/wallet revisions and receipts.
- Deferred COMMIT errors with the same retryable codes run once, close the session
  and return `outcome_unknown`; reopen/discovery confirms the fixture's aborted
  state. This does not infer arbitrary lost-COMMIT outcomes from SQLSTATE.
- Real independent buyers queue before retry and occupy a nonstarting cell of the
  sword footprint while its starting cell remains empty. Explicit placement
  rejects with no debit or pending-income application; automatic placement
  reselects a nonoverlapping footprint and commits once. Editing original offer
  price and nested quantity at the barrier leaves accepted offers unchanged.
  Only these coordination probes extend their own session-local timeouts.
- Wallet concurrency `run-nebp05ol` and Inventory concurrency `run-ico0twha`: PASS.
  They retain cross-operation spend, receiving capacity and custody guarantees.
- Default smoke: 14 Godot checks and 85 Web contracts PASS. Existing NPC Shop
  network regression: server and two headless clients PASS on production SQLite.

No PostgreSQL World/CEF integration, throughput/soak, Linux or P3 execution/fencing
claim. NPC/service/range admission stays with the caller. Ordinary Inventory,
Storage, seller/claim commands and unreceipted checkpoints are not newly opted in.
Raw logs remain ignored under `.godot/verification`; user files are preserved.
