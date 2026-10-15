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

At the third slice, Upgrade was **revision-guarded**, not receipt-backed. Its
operation ID was deliberately empty: UI command correlation was not promoted to
business identity. A repeated stale request returned `stale`. The eleventh slice
below supersedes that limitation with explicit intention IDs and durable receipts.

## Fourth slice: NPC Shop purchase

`WorldDatabase.purchase_shop_operation` delegates to WorldEconomyService and
returns the same local result model; `purchase_shop_offer` remains a dictionary
compatibility method. Shop3D still authorizes NPC/service/range and resolves the
catalog on the server. Only `new_commit` triggers its inventory and wallet facts.

ShopStoreSqlite is unchanged: it resolves the offer, checks exact/first-fit bag
capacity before wallet writes, then commits pending income, price and item
creation atomically. Wallet RAM is accepted only after successful COMMIT.

At this fourth slice, NPC purchases had no durable receipts. This is superseded
by the eighth slice below. Their operation ID was empty and every
successful call created a distinct paid item, even for the same offer. Neither
the offer ID nor UI transport correlation was treated as durable intention identity.
That slice did not add retry/idempotency guarantees.

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

## Eighth slice: durable NPC purchase intentions

NPC Shop purchases require an explicit business operation ID, independently of
browser/native request correlation. ShopUiAdapter creates a random ID for each
new purchase. A timeout, UI reload cancellation or storage uncertainty retains
one unresolved intention in adapter RAM; retrying the same payload reuses that
ID with a new native RPC correlation. A different purchase is blocked until the
old one resolves. A committed/replayed success releases it; a definitive store
rejection following receipt lookup also releases it. Authorization/transport
failure on an uncertain retry is not treated as proof of economic failure.

ShopStoreSqlite composes the existing EconomyCommandSqlite transaction boundary.
The existing account-scoped `market_commands` table stores successful NPC results
under `npc_shop.buy`, atomically with pending income, Yang spend and item creation.
The request fingerprint binds receiving character, canonical shop ID, offer ID and
requested placement. Reusing the ID with different arguments (including another
character of the same account) conflicts. A replay returns the original UID/result
before checking current capacity, balance or offer availability. No new schema,
separate writer, inheritance or generic persistence interface was introduced.

WorldEconomyService accepts wallet RAM only on a new commit. Receipt balance is
historical and never overwrites later income. Shop3D emits inventory/wallet facts
only for a new commit; replay resynchronizes the caller's current views without
another mutation fact. Current NPC/service/range authorization and rate limits
still apply before the economic operation, including replay. Failed commands roll
back and do not add durable receipt rows. Successful receipts are not pruned.

The purchase RPC gains a separate operation ID; matching client/World builds are
required. An empty ID rejects instead of silently bypassing idempotency. Browser
`shop.buy` shape is unchanged because the Godot adapter owns intention identity.
When unresolved, the Shop view exposes a Retry purchase button. The explicit
`shop.retry` Web command accepts an empty payload only; ShopUiAdapter resubmits
the remembered intention and exact original payload. Retry does not pass through
browser Inventory placement validation, so a committed item occupying its target
cell cannot block receipt recovery. A `purchasePending` presentation flag is
republished after state changes and included in `ui.ready` snapshots. The flag
and button do not grant authority: normal server NPC/service/range checks remain.

**Recovery limit:** the adapter and unresolved ID survive browser reload within
the running client, not full client exit/relog. SQLite receipts survive restart,
but automatic discovery/client journaling were not implemented in this slice.
Receipt-only resolution outside NPC range is added in the ninth slice below. This is synchronous single-World receipt safety,
not full durable C2 admission/distributed recovery or durable rejection policy.

## Ninth slice: receipt-only NPC purchase recovery

`shop_purchase_receipt` is a read-only Economy entry point. It fetches only a
successful `npc_shop.buy` result matching the authenticated account and original
receiving character. Unknown IDs, another character/account or another command
kind return `unknown_command`. The lookup does not admit a purchase, write a
receipt, settle Yang or create an item. Its typed result is neither `new_commit`
nor mutation `receipt_replay`; successful lookup repairs current caller views
without mutation facts or replacing wallet RAM with the historical result.

Shop3D exposes this through its authenticated `receipt` RPC action, with a bounded
per-peer read rate. It requires the live authenticated character but no NPC
interaction/range, since it cannot change the economy. Purchase RPC authorization
is unchanged. Retry now checks this read-only result first; if it is unknown,
the adapter may resubmit only its original ID/payload through the existing
NPC-authorized purchase path. An unknown outcome is never silently treated as a
new intention or economic failure.

If NPC context closes while the intention remains uncertain, the adapter keeps
a small `Purchase confirmation` view (`recoveryOnly`, empty offers) with Retry.
It cannot advertise/buy from a stale catalog. Closing that view hides presentation
only and retains the intention; reopening a Shop exposes recovery again. A
confirmed receipt clears the pending intention and closes the confirmation view.
`ui.ready` restores that view from current client state. Browser commands cannot
supply another receipt ID or replace the original purchase payload.

This adds no schema, worker, generic command abstraction or client disk journal.
Full client exit/relog discovery remains deferred. It does not broaden mutation
authorization or claim distributed C2 admission/session fencing.

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

For NPC purchase receipts, existing shop_purchase cases now supply explicit
intentions. Focused checks protect exact result replay, changed-placement and
same-account/different-character conflicts, later pending income, receipt-write
rollback, retry after rollback, reopen with a full bag and one receipt per actual
purchase. Existing shop_network deliberately discards the first committed RPC
response, waits for the real adapter timeout and retries through that same adapter.
The retry now enters through the explicit Web bridge command while the purchased
item already occupies the exact target, and ui.ready exposes retry availability.
A changed unresolved payload is blocked; after resolution, a new purchase creates
a distinct paid item. The existing two-client flow still requires exactly two
inventory and wallet mutation facts. No new test suite was added. Smoke
(10 Godot fixtures, 78 Web contracts) and two-client NPC Shop passed on 2026-10-15.
No native window was launched.

PR #17 review regression: the Web Shop/Inventory fixture simulates a pending
exact purchase whose target is now occupied. A repeated drag stays invalid, but
clicking Retry invokes only the empty-payload recovery action. This closes the
coverage gap left by calling the Godot adapter directly. Review checks passed:
full configured Prettier format check, smoke (10 Godot fixtures, 79 Web contracts)
and the two-client NPC Shop flow. Generated JavaScript matches TypeScript.

For the ninth slice, existing shop_purchase checks receipt-only result semantics,
unknown-ID non-mutation and character/account/kind isolation. The two-client Shop
fixture closes the NPC context and moves the buyer away after losing the committed
response: a fresh buy remains unauthorized, an absent receipt creates nothing,
and Web retry recovers the earlier result without a second charge or mutation fact.
The Web fixture checks a recovery view with no offers, a usable Retry action and
rejection of a recovery snapshot containing a catalog. Smoke (10 Godot fixtures,
80 Web contracts), two-client NPC Shop and full configured Prettier format check
passed on 2026-10-15. No native window was launched.

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

## Tenth slice: NPC purchase client journal

Before sending a new NPC purchase, ShopUiAdapter writes the stable operation ID
and original payload to `user://pending_npc_purchases`. Each immutable intention
has its own JSON file inside a hashed economy/account/character scope. The file
is flushed, closed and renamed before RPC; an unfinished `.tmp` is never sent.
This is process-restart recovery, not a claim of OS/power-loss fsync durability.
No credentials, balances, inventory copies or authority are stored client-side.

The authenticated private Inventory projection supplies `economic_context`:
`authority_id`, Master `account_id` and receiving `character_id`. The authority
ID is a random additive key in SQLite's existing `meta` table, generated once
and retained by normal backup/restore. A fresh dev DB has a different identity,
so reused numeric IDs cannot pick up another economy's intentions. It identifies
the current SQLite economy, not a channel/instance/process or future realm service.
A copied database retains that identity; independently operated copies must not
be treated as separate economies without assigning their own identity.
This adds private snapshot metadata, not a new mutation command or SQL table.

A new adapter restores at most one unresolved intention in that scope and sends
one **read-only receipt lookup**. A committed receipt clears the local file only
after its result arrives; World repairs current views as before. The recovery
window can appear without reopening the NPC or restoring a stale catalog.
An absent receipt retains the intention. Only the player's explicit Retry can
resubmit the original ID/payload through normal NPC/service/range authorization;
startup/relog never automatically buys. This also covers a crash after journal
creation but before RPC. Timeout, disconnect and UI reload retain the file.

Known success or definitive store rejection removes the matching entry. A failed
write blocks sending; failed removal keeps the intention unresolved, preventing
a new ID after an unknown outcome. Corrupt, unsupported or multiple records fail
closed, rather than silently dropping/choosing an intention. The UI reports
`journal_unavailable`; there is deliberately no destructive reset button.
Closing or dismissing the recovery window does not discard an intention.
Immutable filenames avoid overwriting another running client's record; concurrent
clients can still leave multiple records, which require explicit recovery tooling
in a later slice. Server receipts and authorization remain the authority even
when local files are modified or removed.

Verification reuses shop_purchase and the two-client Shop fixture. It checks
scope isolation, corruption, failed disk admission, stable DB identity, a fresh
Godot process reading the saved ID, and a newly composed adapter recovering a lost
committed result outside NPC range with an occupied target. A crash-before-RPC
entry produces one absent-receipt response and no automatic buy. Existing item,
wallet, rollback and exactly-two-commit assertions remain in place. Smoke (10 Godot fixtures, 80 Web contracts), the two-client Shop flow and the
configured Prettier check passed on 2026-10-15. Full desktop
relaunch through Gateway/Master and manual native CEF interaction are not verified
by this headless fixture; no login/session admission behavior was changed.

## Eleventh slice: durable Upgrade intentions

Upgrade now composes the existing EconomyCommandSqlite boundary, using successful
`upgrade` receipts in `market_commands`. The operation ID is explicit and separate
from native/Web request IDs. Empty operation IDs cannot execute a mutation. The
fingerprint binds receiving character, recipe ID, item UID and expected revision.
Receipt insertion, material consumption, pending Yang settlement/spend and item
upgrade/revision commit in the same transaction; a receipt write failure rolls
all of them back. Rejections still do not create permanent receipt rows.

Receipt lookup occurs before mutable candidate/affordability checks. Reusing the
same intention returns its original success after the item revision changes or
the wallet drops below the recipe price. Different intent payloads conflict;
a new operation with an old revision remains stale. WorldEconomyService accepts
wallet RAM only for a new commit and does not replace later pending income with
a historical receipt balance. Upgrade3D repairs current Inventory/wallet views
on replay without emitting another committed mutation fact. NPC/service/range,
living-player authorization and rate admission remain required before replay.
The optional operation-ID argument extends the existing Upgrade RPC specifically
to carry that business identity; the client and World must run matching builds.

UpgradeUiAdapter retains one unresolved intent across CEF reload, prevents a new
payload from replacing it, and exposes empty-payload `upgrade.retry`. Its Retry
button uses the stored original payload even when authoritative presentation
already shows +1, no remaining material or insufficient Yang. `upgradePending`
is presentation state, not server authority. An uncertain response does not show
a definite visual failure. Closing the NPC window keeps the RAM intention;
reopen the original service to retry. No new frontend framework or SQL schema.

This slice does **not** add Upgrade client disk journaling or out-of-range
receipt-only recovery. Unlike NPC purchase, exiting the game loses this adapter's
RAM intention; extending restart recovery to Upgrade is a separate bounded task.
The durable server receipt can still replay a known operation after DB reopen.

Existing upgrade_transaction adds successful replay, payload/character conflicts,
receipt-failure rollback and same-ID retry, later pending income preservation,
replay below current affordability and DB reopen. Existing two-client Upgrade
now discards the first accepted response, waits for the real adapter timeout,
blocks changed intent and retries through the Web bridge after +1 arrived.
Exactly one inventory and one wallet commit fact remain. The Web fixture checks
Retry after +1 without another execute or local affordability/material checks.
Smoke (10 Godot fixtures, 81 Web contracts), two-client Upgrade and the configured
Prettier check passed on 2026-10-15. No native window or manual relog was run.

## Remaining Stage 2 work

Stable intention IDs and full durable result receipts for remaining non-market
operations (Inventory/Storage), Upgrade and broader client-side operation journaling,
durable Economy/World revision reconciliation and broader cache invalidation
remain later reviewable slices. The live presentation delivery versions above
do not implement those distributed contracts. Startup/dev grants and checkpoint wallet flows still retain
their existing entry points. Do not infer distributed C2 admission, durable business
rejections, session fencing or pending-operation recovery from this change.
Existing successful receipts remain durable; bounded rejected-command caching
keeps its current semantics until an explicit persistence change is approved.
