# PostgreSQL pending-only Inventory recovery — P3h

The optional World Inventory runtime now discovers only unresolved account
intents. It no longer pages through terminal history at login, repair or explicit
recovery. Normal gameplay still uses SQLite; this is not a backend cutover.

## Query and schema

`inventory_intents` schema feature version 2 adds one partial index:

```sql
CREATE INDEX inventory_intents_pending_account
ON economy.inventory_intents(account_id, sequence)
WHERE state = 'pending';
```

The existing explicit schema owner upgrades v1 in one transaction; it does not
rewrite/drop intent data, change operation IDs, delete receipts or reset
sequences. Index creation failure rolls back the feature version. Repeated schema
initialization accepts v2. Provision/upgrade this optional schema before serving
traffic: index creation is transactional, not an online concurrent-index rollout.
SQLite schema/migrations are untouched.

`discover_pending_session(context, after, limit)` retains account-lock/session
authorization and sequence-keyset pagination. Filtering happens before LIMIT;
`more` uses the extra pending row, not terminal history. The native executor adds
`submit_session_pending_discovery`, with copied context and existing bounds.
Runtime uses this API; no network RPC, client or worker ownership changes.

`discover_session` and non-session historical discovery still enumerate history
when explicitly requested. Original-ID outcome/receipt/replay APIs are unchanged.
No retention policy or receipt pruning is introduced.

## Recovery races and bounds

Pending work from an earlier alt is discovered account-wide and resumes under
its original issuing character. Completion/removal between pages leaves sequence
gaps, which keyset pagination handles. New work may appear between transactions;
as before, the final pending/freshness ACK is authoritative and restarts bounded
recovery if something is still pending. Pages are not a global frozen snapshot.

At most eight pending intents are admitted per account today. Page/binding/pool
limits and three freshness repairs are unchanged. The partial index removes the
need to enumerate terminal records, while PostgreSQL's index maintenance/vacuum
and total retained data still matter operationally. This is not a promise of
constant latency or a substitute for P4 load/soak acceptance.

## Verification

Existing `inventory-runtime` native acceptance adds 10,000 bulk copies of
already-validated no-op history alongside its original 33 terminal records.
The copies exist only in an owned fixture, with matching receipts; no item
mutations are executed to generate the bulk data.

It checks v1-to-v2 upgrade with data, rollback on a conflicting relation,
idempotent initialization, preserved old outcome/receipt lookup, pending keyset
pages, an operation finishing between pages, alternate-character recovery,
another account's empty pending result, and native EXPLAIN ANALYZE using the
partial index. It then runs existing World cache/replay/failure scenarios through
the new worker path. Session tests cover stale and forged contexts for the new
API; existing history/process-loss tests remain intact.

Use `tools/postgres/run_readiness.py --suite inventory-runtime` and the existing
`inventory-intents`, `inventory-sessions`, `inventory-endpoint` regressions. No new
default suite is added. See [P3h evidence](../evidence/postgres-p3h/README.md).

For what still uses SQLite and the actual remaining adoption/cutover gates, see
the [runtime migration status](../plans/postgresql-migration.md#runtime-adoption-status).
