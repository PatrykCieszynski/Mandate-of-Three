# PostgreSQL P1l — Exchange order settlement parity

This opt-in backend completes order placement, reservation, price-time matching,
partial fills, cancellation and refund in one native PostgreSQL transaction.
Production World/client still uses SQLite. No RPC, CEF, execution worker or
automatic backend switch is introduced.

## Transaction and locking contract

`exchange_orders_schema_postgres.gd` extends the populated ledger schema with
feature `exchange_orders` version 1. Books, orders and fills have explicit foreign
keys, bounded BIGINT amounts, side/status/lot constraints and indexes for pair and
account admission. Reserve shape follows remaining quantity and reduced price.
Schema extension/version marking is atomic, repeatable and rejects future versions.

`exchange_orders_postgres.gd` owns the whole use case on one native connection:

1. Begin, resolve immutable character/account binding, acquire the material/Yang
   book row. Books are narrow pair mutexes, not a global Marketplace lock.
2. Read opposite-side active owners under that pair lock; admit the initiating
   account and all those owners in ascending account ID order, before character
   and receipt admission. Different pairs sharing counterparties use the same
   order. Ledger/Storage/Shop operations never acquire a book after an account.
3. Discover the original receipt before live order/funds checks. For a new order,
   enforce 20 active orders/account and 2048/pair, reduce price and reserve only
   free units. Read makers without `SKIP LOCKED`, sort exact rational prices then
   sequence and execute at maker price. Self-account matching is excluded.
4. Settle integer lots compatible with both denominators; flush each affected
   account's supplied pending Yang once, release buyer limit-price reservations,
   spend execution Yang, transfer material, update both orders and insert fills.
5. Capture wallet revisions/pending prefixes, write the original result/receipt
   and COMMIT. Only a confirmed COMMIT sets `committed`; replay does not.

The pair lock makes the maker set stable through matching. Locking all opposite
owners, including prices that may not cross, is deliberately conservative and
bounded. Its contention/latency under mixed load still needs P2/P4 measurement.
There is no claim that this is high-throughput or nonblocking World execution.

Cancellation resolves a persistent order's pair hint, then rechecks account,
revision and status under pair/account admission. It releases only the remaining
reservation, marks the order cancelled and stores the outcome in that transaction.
Filled/cancelled rows remain available for receipt recovery. No order deletes or
cross-pair order mutation API exists in this slice.

The existing command component now exposes an internal caller-owned admission
step so Exchange can acquire its pair/accounts first. Normal `begin()` still
refuses nested transactions. The Ledger read projection can compose into the
same repeatable-read snapshot as own orders/fills and bounded depth; it does not
open a second transaction. Neither helper is a general transaction framework.

## Failure and recovery

Statement, capacity, reserve or receiving-cap failure rolls back pending income,
wallets/assets, order/fill rows, revisions and receipt together. Transient SQL
errors do not become durable business rejections. Native COMMIT failure closes
the connection and returns `outcome_unknown`; reconnect/discover the original ID
before explicit retry. No fresh-ID compensation or automatic retry is added.

Order/cancel fingerprints preserve existing account-scoped SQLite semantics:
`[have_asset, want_asset, quantity, price_num, price_den]` and `[order_id, revision]`.
Pending Yang is outside the fingerprint. A replay returns its original affected
accounts/wallet states even if current orders changed. A changed payload conflicts.
Receipt scalars `remaining`/`refunded` and affected account IDs use decimal strings
in stored JSON and decode to native integers, with legacy numeric compatibility.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite exchange-orders
```

The existing SQLite implementation is the behavioral oracle for complete account
snapshots, maker-price settlement, exact lot skipping, priority, cancellation,
pending Yang, reservations, fills, revisions, receipts and conservation. Generated
order IDs are named per command; sequence/fill IDs are normalized by relative
order because PostgreSQL identities legitimately have gaps after rollback.

Independent native sessions verify two takers, cancel versus fill, duplicate
commands and two books with reversed counterparties. Fault tests cover each
settlement stage and deferred COMMIT for placement/cancellation, reconnect,
discovery and explicit retry. Overflow, account limit/replay at the cap, exact
account IDs above 2^53, schema rollback/repeat/future guard and nested ownership
are covered. See [evidence](../evidence/postgres-p1l/README.md).

This closes the planned P1 Exchange domain port. Broad cross-operation P2 races,
bounded whole-transaction retry policy, P3 execution/fencing, real PostgreSQL World
load/soak and migration/cutover remain separate gates. Existing SQLite network
tests do not prove PostgreSQL client/CEF integration. Linux and physical CEF input
are not verified here. No installed PostgreSQL service or real player data is used.
