# PostgreSQL P1g — Player Shop seller lifecycle parity

Contract before implementation: opt-in port of Inventory → listing → offer/shop
edit → withdrawal to the receiving character's Inventory. Preserve UID/metadata,
account ownership, provenance, item/offer/shop revisions, complete Shop occupancy,
atomic custody/receipt writes, full-bag rejection, replay and reopen. Compare
observable seller snapshots with migrated SQLite.

Retain the existing account-scoped seller fingerprints (list/edit/cancel/configure),
including cross-alt recovery of the original receipt without retargeting its
receiving character. Preserve bounded temporary negative responses; only success
receipts are durable. SQL/COMMIT failures must not become cached business rejects.

All seller mutations take the account lock before character/capacity/receipt
validation. Storage is never a source or destination; its account lock plus full
footprint contract must not be bypassed. Shop occupies every footprint cell with
a unique database cell key, unlike Storage's start-cell index.

Purchases, seller revenue/collection, legacy account claims, Auction search and
Exchange are separate economic risks and remain unported here. The seller snapshot
does not fake their projections. No runtime/client/network switch, worker, new
gameplay, generic persistence framework or SQLite data import/cutover.

## Schema and transaction ownership

`shop_schema_postgres.gd` adds version 1 of `shop_seller` after the populated
Storage schema. Account Shops, offers and occupied cells are explicit tables.
Escrow custody retains character provenance and adds a separate account, Shop
and offer identity. Composite deferred foreign keys prove matching item owner,
provenance account, Shop owner, offer UID/start and escrow in both directions.
Unique Shop start/offer indexes retain existing invariants, while each occupied
cell has its own unique `(shop_id, position)` key. The service always inserts the
complete footprint. Claims/revenue custody is not admitted as a placeholder.

`shop_seller_postgres.gd` owns listing, offer movement/price, Shop name/status and
withdrawal. Account-first command admission coordinates alts; the receiving
character lock protects Inventory capacity. Listing moves only a tradeable bag
item into escrow, with the same UID/rolls. Withdrawal checks room before removing
cells or changing provenance. It transfers directly to the receiving Inventory,
never silently to Storage or claims. Every provisional row change and success
receipt belongs to one native transaction/session.

Shop geometry is shared through the small `shop_grid.gd`. The SQLite constants
and `_cells()` delegate without changing SQL or behavior. No generic grid,
persistence or command framework is introduced. Existing PG Inventory lookup
already excludes all non-bag/equipment custody, including the new escrow.

## Receipts and recovery

The existing seller fingerprints are intentionally account-scoped and exclude
the current issuer for list/edit/cancel/configure. An alt can recover/replay the
original operation, but the original receipt's item-state character and receiving
placement remain unchanged. Replay does not perform a second transfer to that
alt. This differs from issuer-scoped Inventory/Storage/Upgrade receipts; the port
does not change the legacy Shop contract while moving backends.

`economy_command_postgres.gd` optionally composes the existing bounded
`MarketRejectedCommands`: successful durable receipts take precedence; business
rejections roll back and enter the short-lived cache. Altered payloads conflict
while cached. SQL failures and ambiguous COMMIT results are not negative-cache
entries. Other PG stores retain their previous behavior with no injected cache.
Negative results can expire/evict/disappear at restart; this is not durable C2
rejection/admission. A cache belongs to its owner/thread; fixture workers each
have a separate session/cache. Cross-worker negative-cache coordination is not
implemented or claimed for the future executor.

Native PostgreSQL receipts now encode top-level integer scalar results as
decimal strings as well as the existing item/wallet watermarks. Decode accepts
the prior numeric form and the new string form, returning native integers. This
protects BIGINT Shop IDs/offer revisions above 2^53 without changing the SQLite
codec or client protocol. Historical legacy numbers already rounded through
JSON cannot be repaired by this change; a future import must audit them.

SQL/final receipt failure rolls back custody, occupancy, item/offer/shop revisions
and receiving provenance. Failed native COMMIT retires the session and reports
unknown. Discovery/reopen precedes explicit same-ID retry in the fault fixture;
there is no automatic transport-loss discovery/fencing implementation here.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite shop-seller
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite storage
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite upgrade
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite npc-shop
./tests/run-smoke.ps1
./tests/run-market.ps1
./tests/run-web-inventory.ps1 -Scene market_network
```

Seller fixture snapshots compare SQLite and PostgreSQL Inventory/Storage,
Shop metadata, offered item metadata/price/revisions, complete occupied cells
and receipt counts. Random offer IDs and backend-generated Shop IDs are mapped
to their logical identities; authority IDs alone are removed. PostgreSQL
sequences may retain gaps after rollback; numeric equality of independently
allocated IDs is not the contract. Legacy SQLite read-only receipt scalars are
compared by their integer meanings, matching its existing replay conversion.

Cases cover 1/2/3-cell items, offer-only price, price-only versus position edits,
name/status, stale/owner/geometry/overlap/tradability rejection, equipped/stored
item rejection, full Inventory and direct withdrawal, original cross-alt retry,
reopen, conflict, bounded rejection growth and disappearance of RAM-only rejects.
Faults exercise custody, offer, partially inserted cells, item revision and
receipt on list/edit/configure/withdrawal. Native checks add deferred COMMIT faults
for list/edit/cancel, mutual escrow/provenance constraints, populated schema
extension, repeat/future-version guards and caller transaction preservation.

Independent sessions are barrier-controlled and observed waiting on DB locks
before release: two listings with different starts but overlapping footprints,
two withdrawals of one offer, and one shared withdrawal ID (one commit, one
identical cross-alt replay). BIGINT Shop IDs and result revisions above 2^53 are
recovered exactly. These are targeted seller proofs, not the broad P2 gate.

Windows, Godot 4.7.2, pinned official SOCI v0.4.2 and PostgreSQL 18.6 are verified
on fresh owned SCRAM clusters. The actual World/client remains SQLite. The seller
`mine()` projection intentionally omits unported account claims and revenue; it
is not yet a drop-in replacement for the complete live Marketplace projection.
Purchases/settlement, claims/revenue, Auction reads, Exchange, P2 load/races,
P3 execution/fencing and P4 cutover remain pending. Linux, physical CEF and
PostgreSQL-backed game clients are not verified. No default CI PostgreSQL
service, native binary, credentials or runtime database is committed.
