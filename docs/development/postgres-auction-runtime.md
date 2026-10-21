# PostgreSQL public Auction reads — P3q

P3q optionally connects the existing Auction catalog and indexed search to World
RPCs and the production Trading Glass adapter. Enable the Marketplace runtime's
sixth constructor argument, `auction_search`. Default startup remains SQLite;
this is not a realm backend selector or cutover. Install the existing session and
Auction search schemas before enabling it. No schema or RPC signature changes.

## Ownership and bounds

`auction_runtime_postgres.gd` is one World-scoped read scheduler, owned by the
existing Marketplace coordinator and shared by all map adapters using it. It
submits through the existing bounded native executor; it does not create workers,
connections, durable jobs or a generic queue framework. Mutation account lanes
remain separate. One active native search plus at most 64 total accepted reads
and one queued request per account bound search pressure. A newer queued request
supersedes the previous one with `rate_limited`. Accounts additionally have an
eight-per-second search budget. Endpoint query limits remain independent of writes.

The existing PostgreSQL query builder retains filter, price/upgrade bounds,
negotiable ordering, exact integer values and keyset-cursor semantics. The native
worker validates the current ready delegated session inside its whole transaction,
reads at most `limit + 1` rows and commits/rolls back before releasing the connection.
Only copied rows cross to the World thread, which performs the existing bounded
ItemDefinition/presentation projection. Catalog lookup reuses the static tradeable
definition helper; it does not query SQLite or any other database.

Public search does not hold seller wallet/Inventory locks across a UI lifetime.
Its authorization briefly locks the caller account under the existing session
contract. A search may wait behind that account's mutation. All worker SQL retains
the existing server statement/lock budgets. Search shares the selected bounded
pool with Marketplace work: one search can occupy one worker, and a one-worker
configuration cannot provide parallel seller execution. The test demonstrates
independent work with the existing two-worker configuration, not reserved capacity.

## Correlation, timeout and lifecycle

The PostgreSQL RPC adapter reserves a request ID before payload validation or
endpoint limiting. Pending IDs and up to 64 recent terminal IDs are tracked per
peer/session. Repeating an accepted ID, including a malformed or rate-limited
retry, cannot produce a second terminal response. These are bounded volatile read
IDs, not permanent economic receipts. A request ID may be reused after terminal
history eviction, unless its original native SQL is still outstanding.

Delivery checks the captured Inventory session context and map adapter ownership.
Disconnect, replacement context or disposed adapter suppress stale callbacks.
Queued work expires after two seconds. Active work replies timeout once at that
deadline but retains its native slot until the actual result arrives. It is never
force-closed or joined while SQL runs. Query errors roll back the read, leaving
the worker available for later requests. No query creates command receipts or
publishes committed item facts. Client-side browser generations and `ui.ready`
snapshot recovery remain the existing implementation.

Drain rejects new reads, ends queued deliveries and lets active native work finish
through the existing executor lifecycle. This optional PG path does not participate
in SQLite WAL backup-reader pause/restart; operational PG backup/bootstrap belongs
to the next milestone.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite auction-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite auction-search
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite matching-runtime
& ./tests/run-web-inventory.ps1 -Scene market_network
```

The native runtime suite uses 10,000 legal offers and actual worker sessions with
the existing World/Inventory owner. It checks independent mutation/physics,
session rejection, timeout-slot retention, SQL-error recovery and bounded drain.
Its synthetic admission subcase tests the 64-source queue bound without claiming
65 connected clients. The ten-client endpoint suite retains earlier economic
flows and adds catalog/search, browser reload and mixed-payload duplicate IDs.
See [evidence](../evidence/postgres-p3q/README.md).

This is a local Windows acceptance fixture, not a combat-capacity or P4 soak result.
Normal gameplay still uses SQLite. Provisioning/backend ownership, production
startup/drain/handoff, full PG gameplay, import/restore and explicit cutover approval
remain open. Physical CEF, Linux and distributed failover are NOT VERIFIED here.
