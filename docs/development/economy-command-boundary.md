# Economy boundary — Stage 2 local slices

These are narrow parts of the local Economy architecture work. They harden
the existing WorldDatabase entry points through `WorldEconomyService`, which
composes MarketplaceService for Shop/Exchange and handles upgrade/NPC purchase
orchestration, Inventory activation/equipment/bag-move commands, and item
pickup/account Storage transfers.
This does not complete Stage 2 or introduce a new
service process, generic database interface, queue or database migration.

## Ownership and invariants

- The authenticated World endpoint resolves the character and applies transport
  limits. `open` remains a presentation action, not an economic command.
- `MarketRequestRules.valid_command` owns the shared command shape/range rules.
  The endpoint and application service both use it. A direct application caller
  cannot bypass validation by avoiding the RPC adapter. Malformed commands return
  `request` before a transaction or receipt write.
- Market/Exchange stores still check ownership, custody, revisions, capacity and
  affordability. Their existing `EconomyCommandSqlite` transaction and stable
  command ID/receipt remain the authority. There is no nested transaction.
- A store's `committed` flag distinguishes a **new durable commit** from a
  successful receipt replay. The service reconciles wallets and publishes account
  changes only after a new commit, once per affected account.
- Purchase and order/cancel settlement share one post-commit reconciliation path.
  It updates only loaded account wallets, resets committed pending deltas and
  preserves reservations when the result does not change them. Offline accounts
  remain offline; the SQL transaction has already settled their balances.
- Receipt replay returns the stored business result without resetting newer RAM
  income or publishing another commit. The requesting endpoint still responds and
  refreshes its current views through its existing request flow.

Public response dictionaries, command IDs, SQL schemas and current product rules
are unchanged. In particular, this does not implement the accepted future
claimable-Yang, withdrawal-capacity or Offer Only marketplace changes.

## Second slice: explicit operation results and World effects

`WorldDatabase.market_operation` now returns a small `EconomyOperationResult`.
The existing dictionary API `market_command` delegates to it for compatibility.
MarketplaceService has one execution path; there is no parallel transaction path.

The result contains operation ID, character/account context, action, a copied
business response, `new_commit`, `receipt_replay` and deduplicated changed account
IDs. A malformed/storage-unavailable request may have account ID zero; this is not
an authorization credential. The result holds no live World/player/store references.

- A newly successful transaction has `new_commit=true` and changed accounts.
- A successful mutation receipt replay has `receipt_replay=true`, no new commit
  and no changed accounts. An explicit receipt lookup has both flags false.
- Rejected/failed results have neither flag nor changed accounts. The result does
  not claim that current rejected responses are durable admission receipts.
- World uses this distinction for inventory too: only a new commit invokes
  `accept_committed_change`. Replay resynchronizes current inventory, marketplace,
  Exchange and wallet views for the caller without emitting another mutation.
  A successful explicit receipt lookup performs the same read-only repair, so
  outcome recovery does not require resubmitting the original mutation.

The class is local application data, not a new network envelope, stored receipt
format, event bus or distributed operation state machine. RPC/CEF still receive
the existing business dictionaries. No speculative `pending`/`unknown` statuses
are inferred from the current synchronous SQLite path.

## Third slice: Upgrade through the local Economy boundary

WorldDatabase now lazily owns one `WorldEconomyService`. Marketplace operations,
snapshots and queries delegate through it to the existing MarketplaceService;
that component retains its command rules, receipts and post-commit reconciliation.

Upgrade candidate lookup and execution also enter through this boundary.
The service validates the definition and runtime affordability, passes pending
Yang into the existing UpgradeStoreSqlite transaction, and updates wallet RAM
only after success. The store still atomically consumes material, settles pending
income/spend and increments the item upgrade/revision. There is no outer/nested
transaction and no new SQL schema.

`WorldDatabase.upgrade_operation` returns EconomyOperationResult; the dictionary
`upgrade_item` API delegates to the same path. Upgrade3D reauthorizes the NPC,
service, range and living player as before, then uses `new_commit` to refresh
inventory/combat stats and publish the existing inventory/wallet facts. Quote,
selection, rejection and stale retry do not claim a commit.

Upgrade remains **revision-guarded**, not receipt-backed. Its operation ID is
intentionally empty: the existing UI command ID is transport correlation and is
not silently promoted to durable economic identity. A repeated stale upgrade
still returns `stale`, unlike a Shop/Exchange successful receipt replay. Adding
stable upgrade intention IDs and durable receipts is a later explicit change.

## Fourth slice: NPC Shop purchase

`WorldDatabase.purchase_shop_operation` delegates to WorldEconomyService and
returns the same local result model; `purchase_shop_offer` remains a dictionary
compatibility method. Shop3D still authorizes NPC/service/range and resolves the
catalog on the server. Only `new_commit` triggers its inventory and wallet facts.

ShopStoreSqlite is unchanged: it resolves the offer, checks exact/first-fit bag
capacity before wallet writes, then commits pending income, price and item
creation atomically. Wallet RAM is accepted only after successful COMMIT.

NPC purchases have no durable receipts yet. Their operation ID is empty and every
successful call creates a distinct paid item, even for the same offer. Neither
the offer ID nor UI transport correlation is treated as durable intention identity.
This slice does not add retry/idempotency guarantees to that existing behavior.

## Fifth slice: Inventory activation, equipment and bag moves

`WorldDatabase.inventory_operation` delegates to WorldEconomyService, which
routes activation, equip/unequip and bag moves to the existing ItemStoreSqlite
transactions. Endpoint admission/rate limits and authoritative UID, ownership,
revision, overlap and placement rules remain unchanged. No schema or RPC changes.

ItemStore reports whether its standalone transaction actually mutated state,
resetting that outcome for each command. Equipping an already-equipped item,
unequipping an already-bagged item and moving to the same cell still succeed,
but preserve revisions and do not claim a mutation. The common result now takes
an explicit replay flag; only MarketplaceService supplies receipt replay semantics.
Inventory no-ops are not receipt replays and have no changed accounts.

Only a new item mutation publishes `inventory_changed`. Rejections and
successful no-ops still resynchronize the caller's current authoritative view.
Equipment/runtime combat stats and weapon presentation retain their existing
post-commit refresh path. Inventory operations keep empty operation IDs: UID and
expected revision guard them, without introducing durable intention receipts.
Storage, initialization and ground pickup have not moved in this slice.

## Sixth slice: Ground item pickup and account Storage

GroundLootSystem now submits the server-prepared item and drop UID through
`WorldDatabase.claim_ground_item_operation` / WorldEconomyService. World retains
living-player, loot-rights, expiry, range and line-of-sight authorization plus the
live drop lifecycle. ItemStoreSqlite still commits the existing unique ground
claim, ItemInstance and placement together. Failure retains the live drop; success
or an existing `claimed` receipt removes it, as before. Only a newly committed
pickup refreshes inventory/combat state and publishes a mutation fact.

The existing durable drop claim is not a full business-result receipt: duplicate
claims still reject as `claimed` (or `gone` after despawn), including a different
claimant. They are not represented as successful receipt replay. Operation IDs
remain empty rather than inventing a new client intention protocol.

`WorldDatabase.storage_operation` routes through the same application boundary;
`transfer_storage` remains a compatible dictionary facade. AccountStorageSqlite
retains account membership, ownership/provenance, revision, receiving capacity,
atomic custody transfer and rollback rules. Its new commit outcome excludes the
existing same-cell Storage no-op, which still succeeds without a revision bump.
InventoryEndpoint prepares all affected account peers before publishing and
emits mutation facts only for a new commit. No-op/failure repairs still send
current views without mutation facts. Storage availability rules are unchanged.

No schema, RPC, Yang policy or item-generation behavior changed. Transactions
remain synchronous in the current single World; there is no distributed claim
flow, generic command framework or new persistence worker.

## Seventh slice: live Inventory/Equipment projection versions

InventoryEndpoint stamps each refreshed private full snapshot with a positive,
monotonically increasing `projection_version`. The snapshot includes bag,
equipment, derived display stats and account Storage. Read repair and no-op
refreshes also advance this delivery version; it is not a count of economic
mutations. Publication reuses the prepared snapshot without recomputing stats.

Client intake ignores missing/invalid versions and duplicate/older snapshots
before changing accepted state or notifying the CEF adapter. Public weapon RPCs
carry the corresponding projection version and reject old/duplicate updates per
actor. Accepted private equipment also advances the local weapon model, so an
older public weapon message arriving on the other reliable channel cannot undo
an unequip. Late-join publication includes current weapon versions.

These are **live map endpoint delivery versions**, not durable Economy revisions,
operation receipts or session fencing. The counter is local RAM and a recreated
client endpoint hydrates afresh. Full snapshots may legitimately skip versions:
a newer full view replaces the old one without a delta-replay/gap protocol.
Existing item revisions remain the transactional concurrency contract. Runtime
combat cache refresh and SQL transactions are unchanged; this slice protects
client presentation from stale delivery, not cross-process World cache authority.

CEF continues to receive the same presentation domains. Reload `ui.ready` uses
the accepted current domains, without requiring a new network mutation. There is
no database migration or JavaScript change. The internal weapon RPC gains a
version argument, so client and World must update together; mixed protocol builds
are not supported by this slice.

## Regression evidence

Existing suites protect rollback, ownership and recovery. Their original wallet
replay assertions did not check duplicate commit notifications, and endpoint
validation tests did not protect callers entering directly through WorldDatabase.
Focused cases were therefore added to **existing** `market_purchase` and
`exchange_orders` suites:

- malformed direct commands reject without writes, account facts or wallet change;
- a successful purchase replay and receipt lookup emit no new account changes;
- Exchange rollback and replay emit no new account changes;
- newer pending income survives receipt replay.

The same suites now inspect operation identity, changed-account context and the
commit/replay/lookup distinction. The two-client marketplace race retries the
winning purchase with the same command ID and requires exactly one inventory
mutation fact while the retried client's authoritative inventory remains correct.
It also clears the client's cached inventory/wallet and recovers both through a
receipt-only request, still requiring exactly one real inventory mutation.
No separate class/implementation test suite was introduced.

The existing `upgrade_transaction` suite now inspects the common result for
successful commit, SQL rollback and stale retry, including invalid recipe input.
Its material/Yang/item rollback, ownership, placement and reopen cases remain.
`run-upgrade.ps1` uses two real RPC clients and already requires one inventory and
one wallet mutation fact, selection privacy and range reauthorization. The
transaction suite passed as a baseline before moving orchestration, then these
same contracts passed through the new boundary. No new suite was added.

Likewise, `shop_purchase` passed before its orchestration move. Its existing
rollback, exact-placement, full-bag, pending income and reopen cases remain, with
focused checks for typed commit/failure results and two distinct paid item UIDs.
`run-npc.ps1 -Scenario shop` checks two real clients, private snapshots, NPC/range
authorization and exactly two inventory/wallet facts for two successful purchases.

The existing `item_instances` fixture adds boundary commit/no-op/stale/SQL-fault
checks because previous state-only assertions could not detect false commit facts
or no-ops labelled as receipt replay. Existing swaps/ownership/rollback/reopen
coverage remains. The two-client `web_inventory` flow now includes same-cell move
and repeat-equip successes and checks that only its nine real mutations per player
publish facts, while rejected/no-op responses still repair current snapshots.
Both clients retain private state, runtime-stat reconciliation and reopen checks.
Smoke (10 Godot fixtures, 78 Web contracts), Web Inventory, Market purchase and
Exchange orders passed on 2026-10-15 for this slice. No native window was launched.

For the sixth slice, the existing ground_items partial-write/claim cases exercise
the application boundary and inspect commit/rejection results. The existing
Storage membership, ownership transfer, capacity, rollback and reopen cases run
through the dictionary facade, with a focused same-cell result check. State-only
coverage did not protect against false mutation facts: Web Inventory adds a
same-cell Storage request without increasing its expected real mutation count;
PvE requires exactly one pickup mutation for the winning claimant across failed,
racing and repeated pickup requests. No new test suite was introduced. Smoke
(10 Godot fixtures and 78 Web contracts), run-pve.ps1 and run-web-inventory.ps1
passed for this slice on 2026-10-15.

For the seventh slice, the existing two-client Web Inventory fixture captures
real earlier snapshots, injects them through the production receive handlers
after move/unequip, and requires no state regression or duplicate notification.
It also verifies that reload `ui.ready` returns current inventory/equipment.
Smoke (10 Godot fixtures, 78 Web contracts), Web Inventory and the existing
two-client Market race/receipt-cache recovery passed on 2026-10-15. These are
headless checks, not native appearance/physical input or full reconnect proof.

Relevant commands, run sequentially where they share port 18098:

```powershell
& .\tests\run-market.ps1
& .\tests\run-market.ps1 -Scene market_purchase -Marker MARKET_PURCHASE_OK
& .\tests\run-market.ps1 -Scene exchange_ledger -Marker EXCHANGE_LEDGER_OK
& .\tests\run-market.ps1 -Scene exchange_orders -Marker EXCHANGE_ORDERS_OK
& .\tests\run-combat.ps1 -Scene market_race -MarkerPrefix MARKET_RACE
& .\tests\run-combat.ps1 -Scene exchange_network -MarkerPrefix EXCHANGE_NETWORK
& .\tests\run-market-recovery.ps1
& .\tests\run-pve.ps1
& .\tests\run-web-inventory.ps1
& .\tests\run-upgrade.ps1
& .\tests\run-npc.ps1 -Scenario shop
& .\tests\run-smoke.ps1
```

All commands above passed on 2026-10-15 (smoke: 10 Godot and 78 Web contracts).
The older `market_race` fixture initially failed before its transaction race:
its setup never started the now-required native auction reader. Its setup now
uses WAL, starts the real reader before browsing, and drains it before teardown.
The production search path was not changed to accommodate the fixture.

No native CEF/input/rendering behavior changes in this slice; no native window
check was run.

During the second slice, refreshing the script-class registry through the local
headless editor loaded a saved Terrain3D spike scene and reported a tool-script
`navigation_map` null access. That import is not claimed as a clean editor check.
The affected terrain code was unchanged; runtime economy/network/smoke checks
are recorded separately. Incidental generated import/UID files were removed.

## Remaining Stage 2 work

Stable intention IDs and full durable result receipts for non-market operations,
durable Economy/World revision reconciliation and broader cache invalidation
remain later reviewable slices. The live presentation delivery versions above
do not implement those distributed contracts. Startup/dev grants and checkpoint wallet flows still retain
their existing entry points. Do not infer distributed C2 admission, durable business
rejections, session fencing or pending-operation recovery from this change.
Existing successful receipts remain durable; bounded rejected-command caching
keeps its current semantics until an explicit persistence change is approved.
