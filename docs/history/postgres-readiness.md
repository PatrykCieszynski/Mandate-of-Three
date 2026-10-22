# PostgreSQL readiness (P1a)

**Historical fixture scope:** stage-level backend/default statements below refer
to the original measured implementation, not today's deployment. Normal roles
now use PostgreSQL; migration/adoption is complete. Retained commands, failure
analysis and retry/concurrency contracts remain reference material. Start with
[current full-state setup](../development/postgres-full-state.md),
[persistence](../architecture/persistence-policy.md) and
[migration history](postgresql-migration.md) for current status.

The original P1a evidence below used SOCI v0.4.1. The current dependency is
[v0.4.3](../development/soci-dependency.md), with the readiness fixture rerun on that installed
payload. Historical evidence is retained with its original version labels.

## Contract before implementation

This first Stage 6 / P1 package inventories the SQLite boundary and verifies the
already pinned godot-soci PostgreSQL driver against a disposable local cluster.
It does not port domain stores, switch a realm backend or start an Economy Service.

- Enumerate production SQL consumers and SQLite dialect dependencies. Capture
  the fully migrated schema from a newly created disposable fixture, including
  identity-gated and independent revision migrations; never inspect player data.
- Run only an explicitly owned cluster with a fresh data directory and loopback
  listener. No system service, external DSN, real data import or dual writer.
- Check real Godot/SOCI connections, named int64/NULL/text parameters, explicit
  commit/rollback, transaction failure recovery and bounded independent native
  sessions. Use server-side statement/lock/connect timeouts.
- Check asynchronous completion on the Godot main thread and unrelated session
  progress while another session waits. A worker admission is not a durable
  economic admission; no exactly-once/cross-World guarantee is implied.
- Keep binaries, cluster data, connection details and diagnostic outputs ignored.
  Stop owned PostgreSQL in a finally block. Default smoke stays PostgreSQL-free.

The rollback path is to remove this opt-in fixture and audit tooling; the game
continues using its existing World/SQLite application boundary throughout.

## Reproduce

From the repository root (Python 3.12+, Godot 4.7.2):

```powershell
python tools/soci/setup.py --check
# Optional first-time portable Windows binaries; no service/installer:
python tools/postgres/setup.py
python tools/postgres/setup.py --check
python tools/postgres/run_readiness.py
python tools/postgres/inventory_sql.py
```

The runner also accepts `--pg-bin <directory>` for an existing PostgreSQL binary
distribution and `--godot <executable>`. It never accepts an external DSN or an
existing cluster directory. Each invocation uses a random loopback port, new
`run-*` directory, generated SCRAM password and non-superuser database owner.
Ambient `PG*` variables are removed from client subprocesses to prevent libpq
service/hostaddr redirection. Server limits are `statement_timeout=1000 ms`,
`lock_timeout=750 ms`, `idle_in_transaction_session_timeout=2000 ms`; libpq
`connect_timeout=3 s`. These are fixture bounds, not production recommendations.

Two native worker sessions each admit at most two pending requests. A third
synchronous session owns the lock used to demonstrate independent progress.
This is not a production pool, executor or durable command admission system.

The runner confirms shutdown by addressing its own data directory, never an
arbitrary PID/port, and removes only that stopped cluster's verified data path.
Logs and schema audit remain in `.godot/verification/postgres-readiness/run-*`.
The test explicitly drains native requests before calling blocking `stop()`.
An owned timed-out subprocess tree is terminated before cluster cleanup; no
process-name kill or watcher is used. On restricted Windows execution tokens,
`pg_ctl` may need to be launched outside the agent sandbox (`restricted token`,
error 87); this is not a requirement to install a system service or bypass auth.

The portable Windows archive is PostgreSQL **18.6**, EDB build **18.6-5**;
godot-soci remains **v0.4.1 / b43e37e**, unchanged. The archive URL was resolved
from [EDB's binary downloads](https://www.enterprisedb.com/download-postgresql-binaries),
linked by [PostgreSQL's Windows downloads](https://www.postgresql.org/download/windows/).
`tools/postgres/release.json` pins the observed archive SHA-256; it is a local
integrity pin, not an independently published vendor signature. No native binary
or cluster data is committed. Linux is **NOT VERIFIED**; `--pg-bin` is not a claim
that its full lifecycle has been tested there.

## SQLite baseline and port scope

[Baseline evidence](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/37827015b8536a5b7862cb092d86a7da79dcf988/docs/evidence/postgres-p1a/README.md) captures the integrated
SQLite schema at migration **24**, item revision feature **2** and wallet revision
feature **2**: 26 tables, 23 explicit indexes, 18 triggers and 4 views. The source
inventory contains candidate SQL API calls, SQL-looking literals and dialect
references with file/line anchors. It is not a SQL parser or complete emitted-SQL
reconstruction: expressions/loops and the SDK's table helper remain source code.
The real catalogue closes that particular DDL gap. Internal `sqlite_*` objects,
sequence values, data and the random fixture authority identity are excluded;
this is not a player-data export or cutover manifest.

| Current owner / objects | P1 port requirement |
| --- | --- |
| WorldSchema + WorldStoreSqlite: `meta`, `accounts`, `players` | Preserve trusted Master ID mapping, character IDs and all referenced columns. Split economic identity reads from legacy full-profile writes deliberately. Authentication remains outside this migration. |
| ItemStore + Storage + custody: `item_instances`, `item_custody`, `ground_item_claims`, `item_initializations`; compatibility views `item_placements`, `account_storage` | Port ownership, UID uniqueness, placement/equipment constraints and immediate transactions. Current view writes depend on INSTEAD OF triggers; changing only table DDL is insufficient. Stack footprint overlap also depends on application validation, beyond unique starting cells. |
| Account item revisions: `account_item_revisions` + 6 triggers | Preserve monotonic per-account item state for all canonical custody/item changes, including old/new accounts. No trigger on obsolete placement tables after custody migration. |
| Wallet: `account_wallets` + revision trigger | BIGINT balances/reservations/revisions, nonnegative/cap/reservation constraints; replace recursive SQLite AFTER UPDATE mechanics with explicit PostgreSQL trigger semantics. Pending grinding Yang stays RAM/checkpoint policy until its own durable batch milestone. |
| Shop: `account_shops`, `shop_cells`, `shop_offers`, `account_shop_revenue`, `market_commands` | Port custody and cell invariants, account claimable revenue and receipt identity. Exact request/result encoding and decimal int64 metadata must survive parity; bounded RAM rejection cache is not future C2 durable rejection admission. |
| Exchange: `exchange_assets`, `exchange_orders`, `exchange_fills` | Preserve reservations, inventory/escrow domain linkage, price-time priority, partial fills and cancellation atomicity. Multi-connection race correctness remains P2. |
| Search: `item_affix_index`, offer/item/affix lookup indexes | Port JSON projection triggers and exact normalized/cursor search semantics. PostgreSQL JSON/JSONB is not an automatic substitute for existing TEXT serialization/hash behavior. Index/query plans require PostgreSQL measurements. |
| Legacy/social: `flags`, `guilds`, `guild_members`, `guild_log`, `conversations`, `messages`, `mail`, `mail_state` | These share the current World DB but are not automatically Economy Service tables. Retain on World/SQLite or propose an explicit owner/API migration before removing that connection. Mail claim state may have economic consumers; audit those use cases first. |

Other concrete dialect/API work includes `BEGIN IMMEDIATE`, `PRAGMA`/WAL/backup,
`sqlite_master`, `INSERT OR IGNORE/REPLACE`, `typeof`, `last_insert_rowid`/SDK row
IDs, positional `?` binds, SQLite null-safe `IS NOT`, `RAISE(ABORT,...)` trigger
bodies, JSON1 `json_each/json_extract`, table-builder dictionaries, shared mutable
`query_result` and SDK error/changes properties. Use PostgreSQL's named binds,
explicit transaction API, BIGINT/identity/RETURNING, constraints/trigger functions
and catalogues where appropriate. Do not text-replace the dialect or assume
SQLite serialization proves concurrent safety.

## Findings and remaining gates

Windows headless Godot + the real pinned PostgreSQL driver passed:

- exact near-limit signed int64, UTF-8 and SQL NULL bound roundtrip;
- explicit COMMIT and rollback of an earlier update after a CHECK violation;
- different PostgreSQL backend PIDs, with one worker demonstrably waiting on an
  advisory lock while the other completes and signals on Godot's main thread;
- bounded pending capacity with overflow rejected before scheduling;
- async batch expected-row mismatch rolls back, verified from another session;
- server statement timeout, successful next query, drain and stopped cluster.

Repeated fresh-cluster runs and a run with deliberately invalid inherited
`PGHOSTADDR`/`PGSERVICE` passed; the latter confirms the runner's client environment
isolation. Fresh SQLite catalogues matched the sanitized baseline. Default smoke
also passed 10 Godot cases / 85 Web contracts after restoring the existing pinned
npm dependencies. No production stores, network endpoints or CEF code changed.

No addon changes were needed. Existing project ObjectDB/resource teardown warnings
remain; there was no SCRIPT ERROR in the successful probe. The first sandbox-only
startup failed at `pg_ctl` restricted-token creation; the same owned runner passed
outside that execution restriction and removed its stopped cluster.

The sync native session supports multi-step interactive transactions, but blocks
its calling thread. The async dispatcher owns one session and offers fixed
statement batches, **not an interactive async transaction or connection pool**.
Existing use cases read/validate/choose placement before writing. P1/P3 must keep
those dependent steps on one transaction owner; splitting BEGIN/query/COMMIT
across unrelated dispatchers or yielding an open transaction to gameplay is not
valid. This probe does not choose a production executor/pool size, prove World
tick latency, implement receipts/admission/fencing over RPC, port domain stores,
or satisfy P1's full Item/Wallet/Shop/Storage/Upgrade/Exchange parity gate.

Next: port the realm identity/schema and a complete economic use case with its
existing invariant/replay/rollback contracts. P2 concurrency, P3 nonblocking
execution and P4 recovery/load/cutover remain independent acceptance gates.
