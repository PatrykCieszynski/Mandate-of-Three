# PostgreSQL P2d — Exchange order lifecycle retry evidence

Verified on Windows with Godot 4.7.2, PostgreSQL 18.6 and the official pinned
SOCI v0.4.3 payload. Fresh owned SCRAM loopback clusters and disposable SQLite
fixtures only; owned clusters stopped after verification.

- Exchange orders `run-cyy1a3n6`: PASS, including existing SQLite parity,
  two-taker, cancel/fill, same-ID and cross-book independent-session cases.
- Server-injected statement SQLSTATE `40001`/`40P01` failures roll back the whole
  operation. A fault at the second maker fill leaves exactly two committed fills
  after retry, one pending-income prefix per participant and the original receipt.
  Pair admission, Yang reservation, material refund and receipt failure paths pass.
- Placement and cancellation stop after three total attempts for persistent
  retryable errors. Constraint, lock-timeout and cancellation codes run once;
  all failed attempts preserve economic rows, revisions and receipts.
- Deferred COMMIT errors carrying those same retryable codes run once, return
  `outcome_unknown` and close the connection. Reopen/discovery confirms the
  fixture's aborted transaction left no durable receipt or mutation. This is
  not a claim that arbitrary lost COMMIT responses mean rollback.
- Real independent sessions queued before retry cancel the selected maker or
  fill the cancellation target. Retried placement reselects the current book;
  cancellation rechecks revision and returns `stale` without refund/pending credit.
  Only these barrier diagnostics extend their own session-local timeouts.
- Exchange ledger `run-lv9bf2gp` and Wallet concurrency `run-wpn7gz3r`: PASS.
- Default smoke: 14 Godot checks and 85 Web contracts PASS. Existing headless
  Exchange network fixture: server plus two clients PASS. These clients exercise
  production SQLite, not a PostgreSQL World integration or physical CEF input.

No schema/protocol, runtime backend, shared retry-owner policy or dependency pin
change. Ledger conversion and item custody are not opted in. No contention
throughput, soak, Linux, P3 fencing/execution or P4 cutover claim. Raw diagnostics
remain ignored under `.godot/verification`; unrelated user files are preserved.
