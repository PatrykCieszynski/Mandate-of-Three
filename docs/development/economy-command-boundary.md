# Economy boundary — Stage 2, first slice

This is the first narrow part of the local Economy architecture work. It hardens
the existing `WorldDatabase.market_command` → `MarketplaceService` application
boundary for Shop and Exchange. It does not complete Stage 2 or introduce a new
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

Relevant commands, run sequentially where they share port 18098:

```powershell
& .\tests\run-market.ps1
& .\tests\run-market.ps1 -Scene market_purchase -Marker MARKET_PURCHASE_OK
& .\tests\run-market.ps1 -Scene exchange_ledger -Marker EXCHANGE_LEDGER_OK
& .\tests\run-market.ps1 -Scene exchange_orders -Marker EXCHANGE_ORDERS_OK
& .\tests\run-combat.ps1 -Scene market_race -MarkerPrefix MARKET_RACE
& .\tests\run-combat.ps1 -Scene exchange_network -MarkerPrefix EXCHANGE_NETWORK
& .\tests\run-market-recovery.ps1
& .\tests\run-smoke.ps1
```

All commands above passed on 2026-10-15 (smoke: 10 Godot and 78 Web contracts).
The older `market_race` fixture initially failed before its transaction race:
its setup never started the now-required native auction reader. Its setup now
uses WAL, starts the real reader before browsing, and drains it before teardown.
The production search path was not changed to accommodate the fixture.

No native CEF/input/rendering behavior changes in this slice; no native window
check was run.

## Remaining Stage 2 work

Pickup/equip/upgrade and other non-market economic operations have not been
migrated into this application boundary. A common cross-domain operation result,
versioned inventory/equipment snapshots and broader reconciliation remain later
reviewable slices. Do not infer distributed C2 admission, durable business
rejections, session fencing or pending-operation recovery from this change.
Existing successful receipts remain durable; bounded rejected-command caching
keeps its current semantics until an explicit persistence change is approved.
