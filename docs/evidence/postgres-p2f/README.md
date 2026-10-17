# PostgreSQL P2f — Upgrade retry evidence

Windows, Godot 4.7.2, PostgreSQL 18.6 and the official pinned SOCI v0.4.3 payload.
Fresh owned SCRAM loopback clusters and disposable SQLite fixtures only; owned
clusters stopped after verification. Dependency pin, schema and runtime unchanged.

- Upgrade `run-ik_q2otw`: PASS, retaining SQLite parity, target UID/rolls/sockets,
  ordered material consumption, pending/reserved Yang, upgraded stats, exact
  receipt/reopen, int64 watermarks and transaction ownership checks.
- Server-injected statement SQLSTATE `40001` and `40P01` at custody deletion,
  whole-instance deletion, partial-material update, wallet spend, target upgrade
  and receipt persistence each succeed on the second complete attempt. Material
  cost, target revision/placement, pending prefix and spend occur once.
- Original-result replay performs no new mutations or pending-income application.
  Persistent retryable failures stop after three total attempts. Constraint,
  lock-timeout and cancellation codes run once. Failed attempts preserve item,
  custody, account/item/wallet revisions and receipts.
- Deferred COMMIT errors with those same retryable codes run once, close and
  return `outcome_unknown`; reopen/discovery confirms the fixture's aborted state.
  This does not infer arbitrary lost-COMMIT outcomes from SQLSTATE.
- Independent editors queue ahead of retry while the first upgrade is held at
  a database barrier. A moved material is excluded and current eligible stacks
  are selected; moving the target increments revision and retry returns `stale`
  without consuming materials, pending income or Yang. Updating the original
  recipe while held does not alter the accepted call's captured costs.
  Only these coordination diagnostics extend session-local timeouts.
- Wallet concurrency `run-sawk6p1k` and Inventory concurrency `run-sof33uju`: PASS.
  They retain cross-operation wallet, full-footprint receiving and custody checks.
- Default smoke: 14 Godot checks and 85 Web contracts PASS. Existing Upgrade
  network regression: server and two headless clients PASS on production SQLite.

No PostgreSQL World/CEF integration, throughput/soak, Linux or P3 execution/fencing
claim. NPC/service/range admission remains with the caller; the native store is
still opt-in. Other domain stores and unreceipted checkpoints are not newly opted
into retry. Raw logs remain ignored under `.godot/verification`; user files preserved.
