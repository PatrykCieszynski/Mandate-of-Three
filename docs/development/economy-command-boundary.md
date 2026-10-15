# Economy boundary — Stage 2 local slices

These are narrow parts of the local Economy architecture work. They harden
the existing WorldDatabase entry points through `WorldEconomyService`, which
composes MarketplaceService for Shop/Exchange and handles upgrade orchestration.
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

Relevant commands, run sequentially where they share port 18098:

```powershell
& .\tests\run-market.ps1
& .\tests\run-market.ps1 -Scene market_purchase -Marker MARKET_PURCHASE_OK
& .\tests\run-market.ps1 -Scene exchange_ledger -Marker EXCHANGE_LEDGER_OK
& .\tests\run-market.ps1 -Scene exchange_orders -Marker EXCHANGE_ORDERS_OK
& .\tests\run-combat.ps1 -Scene market_race -MarkerPrefix MARKET_RACE
& .\tests\run-combat.ps1 -Scene exchange_network -MarkerPrefix EXCHANGE_NETWORK
& .\tests\run-market-recovery.ps1
& .\tests\run-upgrade.ps1
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

Pickup/equip, NPC Shop purchase and other remaining economic operations have not
been migrated into this application boundary. Applying the operation result to those
domains, versioned inventory/equipment snapshots and broader reconciliation remain
later reviewable slices. Do not infer distributed C2 admission, durable business
rejections, session fencing or pending-operation recovery from this change.
Existing successful receipts remain durable; bounded rejected-command caching
keeps its current semantics until an explicit persistence change is approved.
