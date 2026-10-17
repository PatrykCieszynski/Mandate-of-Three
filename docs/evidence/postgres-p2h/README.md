# PostgreSQL P2h — Inventory command retry evidence

Windows, Godot 4.7.2, PostgreSQL 18.6 and official pinned SOCI v0.4.3. Fresh owned
SCRAM loopback clusters and disposable SQLite only; owned clusters stopped after
verification. Dependency pin, schema, public receipts and runtime remain unchanged.

- Inventory `run-ntpyaztm`: PASS, retaining SQLite parity for starter/pickup,
  custody/footprints, move/equip/activate/unequip/swap, equipped stats, receipts,
  reopen, nested transaction ownership and ambiguous COMMIT containment.
- Server-injected statement SQLSTATE `40001`/`40P01` at placement, target revision
  and receipt writes succeed on the second complete attempt for all five command
  paths. Two-item swap changes both custody records atomically, increments each
  affected item revision once, preserves UID count and produces correct stats.
- Original-result replay performs no new mutation and reports `receipt_replay`
  without `committed`. A newly receipted no-op can retry its receipt write while
  preserving both the item snapshot and mutation flag; its replay is distinguished.
- Persistent retryable failures stop after three total attempts. Constraint,
  lock-timeout and cancellation codes run once. Failure snapshots preserve item,
  custody, account revisions, receipts, initialization and ground-claim markers.
- Deferred COMMIT errors with the same retryable codes run once, close the session
  and return `outcome_unknown`; reopen/discovery confirms the fixture's aborted
  state. This does not infer arbitrary lost-COMMIT outcomes from SQLSTATE.
- Real independent editors queue before retry and move the target (stale),
  unequip the previously worn weapon (retry selects current equipment and leaves
  the former weapon's new placement/revision intact), or occupy a nonstarting
  cell of the unequip footprint (occupied, no partial unequip). Only these barrier
  diagnostics extend their own session-local timeouts.
- Inventory concurrency `run-a1plhbj6` and Storage `run-1_qelwht`: PASS, retaining
  cross-alt receipt, full-footprint receiving and cross-operation custody checks.
- Default smoke: 14 Godot checks and 85 Web contracts PASS. Existing Web Inventory
  network regression: server and two headless clients PASS on production SQLite.

No PostgreSQL World/CEF integration, physical UI-input, throughput/soak, Linux or
P3 execution/fencing claim. Account Storage, Shop seller/claims, starter/pickup and
unreceipted checkpoints are not newly opted into retry. Raw logs remain ignored
under `.godot/verification`; all pre-existing user files are preserved.
