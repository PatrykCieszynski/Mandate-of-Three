# PostgreSQL P1h — Player Shop settlement parity

This opt-in port completes one economic guarantee: a fixed-price Player Shop
purchase transfers exactly one escrow UID into the buyer's Inventory, spends
available Yang including the caller's pending income, credits offline seller
proceeds and records the original outcome atomically. Seller proceeds can then
be collected partially up to the existing wallet cap. World remains on SQLite.

## Behavioral contract and ownership

`shop_settlement_postgres.gd` owns purchase and proceeds collection, composing
the existing command owner, Inventory receiving contract and wallet mutations.
`shop_seller_postgres.gd` continues owning listing/edit/configure/withdrawal.
There is no new dispatcher, worker, generic database interface or runtime switch.

The purchase fingerprint remains `buy` plus
`[character, shop, offer, expected_revision, expected_price]`. Collection remains
`claim_revenue` plus `[character]`. Pending income is server-supplied execution
context, excluded from the fingerprint; replay returns its original committed
application without applying a new delta. Shop receipt discovery remains scoped
to the authenticated account, matching SQLite. Same-account use of the same ID
with a different issuer/fingerprint is a conflict.

Validation preserves self-trade, paused Shop, offer-only, stale revision/price,
unknown definition, reserved-funds and full receiving Inventory behavior. Receipt
lookup precedes mutable offer/capacity/funds checks. A sold offer can still replay.
The receiver is the original issuing character, with first-fit Inventory placement;
there is no Storage or account-claims fallback and no new placement protocol.

One native transaction owns pending buyer income, spend, additive seller revenue,
complete Shop-cell removal, item owner/revision, custody provenance/placement,
offer deletion, item/wallet watermarks and the success receipt. The seller need
not have an actor or loaded runtime wallet. Seller grinding income is not applied
by a buyer's purchase. Seller wallet balance is unchanged until collection.

Collection locks the account, character and wallet before computing headroom:
`min(revenue, MAX_YANG - committed_balance - pending_income)`. The same transaction
credits pending income plus collected proceeds and subtracts only the collected
amount. Reservations remain intact; the remainder stays claimable. Empty revenue
and no headroom preserve the existing `nothing_to_claim` / `wallet_full` results.

## Schema and lock order

`shop_settlement_schema_postgres.gd` adds explicit feature version 1 after the
seller schema. `account_shop_revenue` has one FK-backed account row, nonnegative
BIGINT Yang and no per-sale history. Repeat bootstrap preserves populated escrow
and existing receipts. Historical direct-wallet receipts are never backfilled into
new claimable proceeds. This is schema parity, not a SQLite import tool.

Purchase resolves an immutable Shop-to-account hint, then the command owner locks
buyer and seller account rows in ascending ID order using `FOR NO KEY UPDATE`,
before locking the issuing character and consulting receipts. The authoritative
offer and Shop status are read again after admission, and the seller must match
the locked hint. Missing offers do not prevent receipt replay. No store operation
in this port changes a Shop's account identity or deletes Shops.

Seller commands use the same account domain; buy/cancel/edit and two sales to one
seller therefore serialize. Reciprocal purchases use the same sorted lock order.
Different account pairs have no application-level global lock. Revenue uses an
additive, overflow-guarded UPSERT with RETURNING, not an unlocked read/overwrite.
Revenue is capped by signed BIGINT, separately from the lower wallet cap.

Wallet checkpoints do not use account admission. Collection therefore explicitly
locks the wallet row before calculating partial headroom. Conditional wallet spend
still protects reservations and funds. Inventory capacity uses the existing
character lock and full-footprint receiving implementation. Nothing mutates
account Storage or bypasses its account/full-footprint contract.

## Failure and recovery

Statement errors roll back the whole transaction and do not become durable or
cached business rejections. Success receipts are durable; bounded existing RAM
negative admission remains session/thread-owned. Revenue overflow is a business
rejection that rolls back provisional buyer spend and pending income as well.

An unsuccessful native COMMIT closes the session and returns `outcome_unknown`.
The caller must reopen and discover the original operation before an explicit
same-ID retry. This port does not add automatic retries, in-flight discovery,
runtime pending-delta ownership or C5 fencing. Those remain P2/P3 gates. A lost
response must never lead to generating a fresh purchase ID.

Purchase account IDs, Shop ID and balance are encoded as decimal strings in
receipts, then decoded as native integers. Revenue remainder is already a decimal
string; existing item/wallet watermark and claimed-amount encoding is reused.
Legacy numeric receipt decoding stays supported without claiming it can recover
precision already lost by an older writer.

## Verification and limits

Run the dedicated disposable native fixture:

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite shop-settlement
```

The fixture compares SQLite/PG Inventory, owner/provenance/revisions, funds,
reservations, wallet/item watermarks, revenue, occupied-cell totals and receipt
counts. It covers rejection, full bag, partial collection, response loss/reopen,
same-ID replay/conflict, overflowing revenue, mutation/receipt fault rollback,
deferred COMMIT failure and exact BIGINT proceeds/identity recovery. Native
conflicts use independent worker-owned SOCI sessions, held at an observed SQL
lock barrier: same-offer double buy, buy/cancel, buy/edit, additive different sales,
same-ID purchase with pending income, same-ID collect, reciprocal buys and
competing purchases from two alts sharing insufficient wallet funds.

The seller-only `mine()` projection is unchanged. Revenue is available explicitly
through the settlement store; a complete PostgreSQL Marketplace projection,
legacy account claims, public visit/Auction reads and Exchange still need ports.
No PostgreSQL-backed client or physical CEF behavior is claimed. Targeted races
are not the broad P2 gate, load/soak, executor, multi-World or cutover acceptance.
Linux is not verified. Setup/evidence: [P1h evidence](../evidence/postgres-p1h/README.md).
