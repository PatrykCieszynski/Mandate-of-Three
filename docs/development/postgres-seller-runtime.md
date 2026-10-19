# PostgreSQL seller operations and account claims — P3m

P3m optionally connects `list`, `edit`, `cancel`, `configure` and item `claim`
to bounded native PostgreSQL workers through the existing Marketplace RPCs.
Normal startup remains SQLite. Buyer settlement, proceeds collection, Exchange
and public Auction search are separate runtime adoption work.

## Ownership and transaction boundary

`seller_postgres_adapter.gd` owns current-map admission, transfer checks, response
correlation and publication. `seller_runtime_postgres.gd` coordinates execution,
receipt discovery and local Inventory readiness. `seller_session_postgres.gd`
executes the existing seller/claim stores inside a worker-owned connection.
The endpoint contains no SQL and the browser has no economic authority.

All five mutations require the current delegated session context. Raw legacy
store calls cannot bypass that fence for registered accounts. Existing account
locks, ownership, full-footprint/capacity checks, revisions, escrow and receipt
transactions remain authoritative. No direct Storage writes, new schema, durable
admission queue or wallet capture are added by this slice.

There is one active seller operation per account, including unresolved detached
accounts, with a maximum of 64 and the native executor's bounded capacity.
Queue refusal does not retain a mutation for later execution. Unrelated accounts
can progress while one waits for an SQL lock. World polls results without waiting
for SQL on the simulation thread.

## Reconciliation and uncertain outcomes

The coordinator holds Inventory readiness during execution. After a known
outcome it reloads Inventory, waits for its revision ACK and loads the private
shop/claims snapshot. That snapshot includes an account item-state marker read
under the same transaction lock. Publication requires agreement with the current
acknowledged Inventory marker; a newer private view invalidates Inventory, and a
newer Inventory marker triggers another private read. Repair is bounded.

Only a known new commit produces a committed fact. Receipt replay is not another
commit; price/name edits do not generate item-change facts. Callbacks recheck
the current session before final delivery. Private snapshots never broadcast
another account's claims or bag.

An ambiguous COMMIT pauses delivery and initiates only bounded read-only receipt
discovery. Receipt lookup is account + original command ID + seller kind, so an
authorized alt can discover an original outcome even after the RAM lane retires.
It does not retarget the original mutation to that alt's inventory. A missing
receipt does not imply failure; only explicit client retry may execute the same
saved body and ID after current authorization. SQL errors are not silently retried
as new economic operations.

Shutdown closes admissions/recovery scheduling and drains and joins accepted
native work. Once all worker sessions stop, unresolved deliveries can be deferred
to receipt discovery on reconnect, with bounded operator diagnostics. No RAM
currency/value is held by this coordinator. Wallet/NPC dirty-value barriers remain
independent.

## Client recovery

The production `MarketUiAdapter` uses a character-scoped local seller journal.
It generates a native stable command ID and saves the original action/body before
sending. Browser reload, UI recreation and client-process relog discover that ID
without requiring the original browser command or an item still in the bag.
The existing market window's Retry action invokes explicit `market.retry_seller`.

Opening a window with a restored intent performs read-only discovery first.
If the journal was saved but never sent, reopening does not execute it. An explicit
retry may submit its original payload. Uncertain/transient responses keep the
journal; confirmed success/terminal rejection clears it. SQLite's existing client
command behavior and revenue journal remain unchanged.

## Verification and remaining boundaries

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite seller-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite shop-seller
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite account-claims
& ./tests/run-web-inventory.ps1 -Scene market_network
```

Run network suites sharing 18098/18099 sequentially. See
[P3m evidence](../evidence/postgres-p3m/README.md) for native fault tests and seven
actual client processes. These clients use production RPC/bridge/adapters with
controlled Gateway entry/map/session fixtures, not a physical CEF playthrough.

Existing claim limits (200 backend rows, 20 displayed items) remain; complete
pagination is still R6. Local marker fencing does not supply cross-process
invalidation/publication. Buyer/proceeds/wallet settlement, Exchange, public PG
search, production bootstrap/handoff, Linux, whole-server crash acceptance and
P4 load/soak/import/restore/cutover remain open.
