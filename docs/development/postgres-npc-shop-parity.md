# PostgreSQL P1c — atomic NPC purchase parity

Status: opt-in PostgreSQL persistence port of the existing
NPC purchase, not a runtime switch, new Shop feature or new client/network path.
One synchronous SOCI session owns capacity, pending Yang/spend, UID + character
custody, account item/wallet revisions and the durable success receipt together.

Required checks: exact/first-fit footprint placement, no rotation/page overflow,
full bag before spending, server-authored quantity/cost, same UID/result on retry
after a lost response/reopen/full bag, account/receiving-character/kind isolation,
request conflicts, no receipt growth on rejects, item/wallet/receipt/COMMIT faults
without partial writes, and exact integer watermarks in recovered receipts.

The schema supports character bag/equipment custody only. It rejects Storage,
Player Shop escrow and account claims until their explicit domain migrations.
Mutual deferred foreign keys require item + matching owner custody at COMMIT;
account revisions share the same transaction. Capacity takes the character row
lock; this is not a realm-wide writer/queue or a complete P2 concurrency claim.

The durable receipt JSON codec is shared with existing SQLite; public SQLite
methods remain compatibility delegations. There is no general database interface
or SQL transpiler. Rejects remain non-durable under the current local contract;
future C2 durable admission/rejection and P3 outcome discovery/fencing are deferred.

Existing NPC admission/UI/journal/retry behavior remains on SQLite. The PostgreSQL
fixture exercises retry at the persistence boundary and does not claim an async
World connection pool, new RPC integration or full P1 inventory mutation parity.

## Implementation and recovery

`npc_shop_schema_postgres.gd` adds a separately versioned feature alongside the
wallet schema. `item_store_postgres.gd` provides trusted, immutable character to
Master account binding, character Inventory reads and transactional receiving.
The mutual deferred references prevent a committed orphan item or custody row
with a different character owner. Starting cells/equipment slots are unique;
footprint validation uses the existing shared InventoryGrid and locks the character
row until the use case commits. This is a prerequisite, not full independent-
connection race proof or a port of equip/move/drop/ground pickup.

`economy_command_postgres.gd` owns command identity, the existing canonical request
fingerprint, success receipt and transaction result. `npc_shop_store_postgres.gd`
uses server-resolved ShopDefinition/ShopOfferDefinition data, checks capacity
before wallet writes, then creates one item/stack plus custody and receipt before
COMMIT. Rejects do not leave durable receipt rows. The account-scoped command ID
cannot be reused with another character/payload/kind. Replaying a committed command
returns its original UID and watermarks before rechecking current bag space or
funds, and never reapplies newer pending income.

Read-only receipt recovery filters the account, kind and a dedicated BIGINT
receiving-character column. It does not recover identity by parsing JSON numbers
as doubles. The fixture checks a character ID above 2^53 as well as item/wallet
watermarks above 2^53. Future SQLite import must populate that receiver column
from the original purchase request using exact numeric parsing; this PR does not
perform a data migration. The existing decimal-string receipt format is unchanged.

The shared `economy_receipt_codec.gd` contains the original SQLite codec without
semantic changes; old static methods delegate to it. PostgreSQL does not depend
on a SQLite command/connection implementation.

A failed native COMMIT closes the session and returns `outcome_unknown`. The
fixture injects a deferred failure after item/wallet/receipt writes, reconnects
and verifies the actual committed state. It does not equate missing response with
rejection or implement an automatic retry on unknown status. Actual transport-loss
discovery, in-flight admission/fencing and async World execution remain P3.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite npc-shop
./tests/run-smoke.ps1
./tests/run-market.ps1 -Scene market_purchase -Marker MARKET_PURCHASE_OK
./tests/run-market.ps1 -Scene exchange_orders -Marker EXCHANGE_ORDERS_OK
```

The new opt-in fixture compares PostgreSQL and migrated SQLite snapshots for the
same purchase contract, normalizing only independently generated UIDs/authority
identities. It checks partial-write faults, replay after reopening with a full bag,
pending-income preservation, exact/first-fit/overlap/page bounds, authored stack
amount, receipt isolation/conflict, rejection row growth and high integer values.
PostgreSQL-specific cases check COMMIT rejection, mutual custody ownership and
orphan constraints, and valid/invalid 1x3 placement bounds.

All database tests use new disposable fixtures, with SOCI v0.4.2 and PostgreSQL
18.6 on Windows. Existing SQLite UI/journal tests continue to cover client intent
recovery in the current runtime. Linux, PostgreSQL-backed clients, equip/move,
account Storage/Player Shop/Upgrade/Exchange, P2 races and cutover are not verified
or implemented by this slice. No PostgreSQL work is added to default CI.
