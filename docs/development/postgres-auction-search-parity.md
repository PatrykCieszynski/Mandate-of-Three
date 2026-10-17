# PostgreSQL P1j — Auction search parity

This opt-in slice ports bounded Auction search SQL and the transactional rolled
affix projection. It preserves existing filters, result metadata, price ordering,
offer-only semantics, validation and keyset cursors. Production World remains on
its current asynchronous SQLite/SOCI reader; no PostgreSQL executor, pool,
admission change, endpoint or client protocol is introduced.

## Shared contract and backend ownership

`auction_search_contract.gd` contains the existing pure query builder and
main-thread row projection. `MarketSearchSqlite.build_query/project_rows` remain
compatibility delegations, including the existing project_rows database argument.
Projection never needed database I/O; it resolves ItemInstance/ItemDefinition
metadata from copied rows. Catalog normalization/discovery remains unchanged.

The PostgreSQL mode qualifies tables with `economy.` and uses explicit C collation
for offer-ID ordering/continuation, matching SQLite binary ordering of lowercase
hex IDs. Price mode remains fixed-price entries first, ordered price ASC or DESC,
then ascending offer ID; negotiable entries follow fixed-price entries for either
sort and continue by ascending offer ID with a zero-price cursor marker.

The shared builder explicitly casts isolated negotiable-price parameters to BIGINT.
This preserves SQLite behavior and avoids PostgreSQL inferring a 32-bit parameter
from comparison with a small literal. All values remain bound parameters; no
player-provided SQL/table/column/sort fragments are accepted.

`auction_search_postgres.gd` owns only a caller-supplied synchronous session.
`search(payload)` validates before SQL, refuses a caller's open transaction, runs
one SELECT with a native row cap of `limit + 1`, rejects native errors/truncation,
and projects at most the requested limit (1–50). It leaves no open transaction.
`build_query()` also exposes copied SQL/parameters for a later worker integration.
No synchronous query is added to the World tick or marketplace application path.
Native session/thread ownership and main-thread presentation remain explicit.

Filters preserve definition, inclusive upgrade/price ranges and up to four
distinct rolled-affix AND predicates using EXISTS. Duplicate rolls do not duplicate
offers; effective combat/base/upgrade stats are not used to satisfy rolled filters.
Negotiable entries appear only when price filters span the full accepted range.
Each page is a fresh live read, as before; this does not promise an immutable
catalogue snapshot across multiple UI pages while listings change.

## Projection schema and failure behavior

`auction_search_schema_postgres.gd` adds version 1 of `auction_search` after
populated claims/Shop state. It creates `item_affix_index(uid, ordinal, stat_id,
value)`, UID/ordinal uniqueness, FK cascade and finite DOUBLE PRECISION values,
plus stat/value/UID and UID/stat/value indexes. Definition/upgrade/UID and
price/offer indexes support filtering. Existing UID/Shop/custody constraints stay.

Existing valid affix arrays are backfilled with zero-based ordinality. An AFTER
INSERT / UPDATE OF affixes_json trigger refreshes the projection in the item's
own transaction; unchanged affix text is a no-op. Searches never parse JSON.
Deletion cascades projection rows. Trigger failure rolls the item mutation back,
and DDL/backfill/feature marking are one migration transaction. Malformed affix
content fails migration/mutation rather than silently manufacturing numeric values.
This is not an importer/repair policy for arbitrary historical corrupt data.

Repeat bootstrap preserves content; future feature versions refuse readiness.
Failed schema COMMIT follows the existing close/refusal behavior. SQL errors in
standalone native reads return storage; no success receipt or rejection row is
created by a query. Session connect/read-only role policy, automatic retries,
deadlines/cancellation and worker lifecycle belong to P3. The current SQLite
scheduler and backup/drain/recovery code are unchanged.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite auction-search
```

The native fixture creates identical valid three-Shop SQLite/PostgreSQL data and
compares every row and cursor across full pagination: definitions, no-result
queries, both price orders, tied prices, negotiable continuation, AND predicates,
duplicate rolls, upgrade/price bounds and page sizes. It checks malformed payloads/
cursors, populated backfill, failed schema rollback, projection update/rollback,
delete cascade, injected projection failure, nested transaction refusal, closed
connection/reopen, read-only session use and repeat/future-version guards.

A separate benchmark portion seeds exactly 10,000 active offers across 500 Shops
with valid two-cell occupancy and account/character provenance, in bounded owned
transactions. Earlier parity Shops are paused. It runs ANALYZE and records 30
samples each for 0/1/2 affix filters, native call versus projection-inclusive time
and EXPLAIN. These are local synchronous query observations, not World tick,
concurrent load, cross-backend speed claims or a P4 acceptance result.

See [P1j evidence](../evidence/postgres-p1j/README.md). PostgreSQL-backed clients,
physical CEF, Linux, mixed reads/writes under load, P3 execution/fencing and cutover
are not verified. Exchange ledger/matching remains a separate P1 domain port.
