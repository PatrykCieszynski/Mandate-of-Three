# PostgreSQL transaction retry and uncertain outcomes

Normal development uses PostgreSQL. This document keeps the transaction-owner
failure contract established during migration. Runtime ownership, checkpoints
and deployment are described in [persistence](../architecture/persistence-policy.md)
and [full-state setup](postgres-full-state.md).

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
invocation starts fresh identity/admission, receipt lookup, current offer/revenue
or order-book selection, capacity/headroom and economic validation, then mutation/receipt/COMMIT.
The initiating character and command ID remain identical. Purchase captures a copy
of its server-owned pending-income prefix once; collection retains the original
integer prefix. An aborted attempt rolls that prefix back with every other write.
This is not a statement retry or reuse of first-attempt selection decisions.

Success, receipt replay, a business rejection, exhausted attempts, a closed session
or any unproven cleanup terminates the loop. There is no yield/backoff/pool or
unbounded work queue. Normal World dispatch uses the PostgreSQL domain runtimes and workers; this
policy describes transaction retry inside the store owner, not RPC resubmission.

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

## Verification and provenance

Select the relevant operation suite from [testing](testing.md); transaction
lifecycle behavior is covered by the `commit-failure` fixture. Use disposable
PostgreSQL data, never player databases.

The original P2c–P2k per-operation narrative and dated test results are available
in [Git history](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/37827015b8536a5b7862cb092d86a7da79dcf988/docs/development/postgres-transaction-retry.md).
The [migration milestone](../history/postgresql-migration.md) records completion.
Routine verification belongs in the PR, not in additional stage reports.
