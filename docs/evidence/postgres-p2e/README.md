# PostgreSQL P2e — Exchange stack conversion retry evidence

Windows, Godot 4.7.2, PostgreSQL 18.6 and official pinned SOCI v0.4.3.
Only fresh owned SCRAM loopback clusters and disposable SQLite fixtures were used;
owned clusters stopped after verification. No schema or dependency pin changes.

- Exchange ledger `run-5z02fh4u`: PASS, including existing SQLite parity,
  competing native deposits/withdrawals, one-UID conversion versus Storage transfer,
  original receipt recovery and transaction ownership.
- Server-injected `40001`/`40P01` statement faults verify two-attempt success for
  partial and whole stacks in both Inventory and shared Storage. Ledger credit,
  stack remainder/revision/provenance, deletion and receipt settle exactly once.
  An alt may convert shared Storage while retaining the original stack provenance.
- Inventory and account-claim withdrawals fault at custody creation or receipt
  persistence. Rollback removes the provisional generated UID; retry creates one
  durable item/custody, debits once and replays the identical original result.
- Persistent retryable faults stop after three total attempts for both directions.
  Constraint, lock-timeout and cancellation codes run once. Economic snapshots,
  item/account revisions and receipts remain unchanged after exhausted attempts.
- Deferred COMMIT errors carrying `40001`/`40P01` run once, close the session and
  return `outcome_unknown`. Reopen/discovery confirms the fixture's aborted state
  has no receipt. This does not infer arbitrary lost-COMMIT outcomes from SQLSTATE.
- A real independent Storage withdrawal queues before converter retry and moves
  its source UID to the alt's Inventory. Retry reauthorizes, rejects the obsolete
  source and grants no ledger credit. The full stack has one new owner/revision.
  Only this barrier diagnostic extends its own session-local timeouts.
- Storage `run-f2nj3d0e`, Inventory concurrency `run-_1c33dua` and Exchange orders
  `run-u6rr_ed3`: PASS. These retain account-first admission, full-footprint/last-space
  receiving, UID custody, cross-alt receipts and order settlement guarantees.
- Default smoke: 14 Godot checks and 85 Web contracts PASS. Existing Exchange
  network regression: server and two headless clients PASS on production SQLite.

Runtime World remains SQLite. No PostgreSQL World/CEF integration, throughput,
soak, Linux or P3 execution/fencing claim. Ordinary Inventory/Storage commands are
not newly opted into retry. Raw logs remain ignored under `.godot/verification`;
all pre-existing user files are preserved.
