# PostgreSQL P2c — receipt-backed settlement retry

This opt-in slice adopts official SOCI v0.4.3 and enables bounded whole-use-case
retry for **Shop purchase and revenue collection only**. Production World remains
SQLite; no executor, connection pool, RPC, schema or backend selection is added.

## Policy and ownership

The existing `economy_command_postgres.gd` owner captures native structured error
details **before** rollback clears them. It records an internal retry proof only
when the failure is storage-related, `error_backend` is PostgreSQL, SQLSTATE is
`40001` or `40P01`, an explicit transaction is active, and native rollback succeeds.
The owner separately records whether native COMMIT was attempted and vetoes retry
across that phase. Other error codes and message text cannot authorize retry. Failed rollback
closes the session and never produces that proof. Missing structured diagnostics
fail closed. No retry metadata is added to public results or receipts.

`run_with_retry()` invokes the complete operation at most three times. Each
invocation starts fresh identity/admission, receipt lookup, current offer or revenue
selection, capacity/headroom and economic validation, then mutation/receipt/COMMIT.
The initiating character and command ID remain identical. Purchase captures a copy
of its server-owned pending-income prefix once; collection retains the original
integer prefix. An aborted attempt rolls that prefix back with every other write.
This is not a statement retry or reuse of first-attempt selection decisions.

Success, receipt replay, a business rejection, exhausted attempts, a closed session
or any unproven cleanup terminates the loop. There is no yield/backoff/pool or
unbounded work queue. These synchronous stores remain outside the World simulation
path; P3 must provide bounded nonblocking execution before runtime adoption.

COMMIT failure keeps the existing conservative policy: close and return
`outcome_unknown`, then discover the original receipt after reconnect. Even a
COMMIT error carrying `40001`/`40P01` does not enter the statement-rollback loop.
Unreceipted Wallet checkpoints and other domain stores are not opted in.

PostgreSQL requires retry of the full transaction, including decisions about SQL
and values. SQLSTATE alone is insufficient for application retry safety. See
[official serialization failure guidance](https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html).

## Native lifecycle gate on the released payload

`postgres_commit_failure.gd` retains its existing native failure containment check
and verifies v0.4.3 naming/reset and transaction semantics. A failed deferred COMMIT
can leave local `in_transaction()` true after PostgreSQL has ended and rolled back
the transaction. An ordinary statement failure instead leaves subsequent statements
failing with `25P02`. COMMIT of that aborted transaction can return true while
PostgreSQL performs ROLLBACK. No boolean or local flag substitutes for the owner's
statement tracking, durable receipt or outcome discovery.

## Verification and remaining scope

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite commit-failure
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite shop-settlement
```

The existing settlement fixture now injects server SQLSTATE failures at custody
and receipt writes after prior wallet/revenue changes. Sequence counters survive
rollback and measure attempts without writing fake economic receipts. It verifies
two-attempt purchase/collect success, one application of pending income, original
result replay, a three-attempt cap, no retry for constraints/timeouts/cancellation/
generic errors, and no retry/discovery substitution after COMMIT or rollback failure.

An independent editor is queued ahead of the retried buyer while the first attempt
is held at a database barrier. After rollback, the editor changes price/revision;
the next complete purchase reads it and returns `stale` without debit. Only this
diagnostic uses larger session-local timeouts to coordinate its native threads;
normal fixture limits and the three-attempt budget remain unchanged.

This is fault/recovery correctness, not a contention-throughput or soak benchmark.
See [evidence](../evidence/postgres-p2c/README.md). Other use cases need explicit
adoption/review, not a global retry toggle. P3 pending-prefix ownership, session
fencing and runtime reconciliation, P4 migration/load/cutover and Linux native
verification remain separate gates. An internally retried call does not make the
same pending prefix safe across multiple successful commands with different IDs.
