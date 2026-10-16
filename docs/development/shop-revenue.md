# Collectable player-shop revenue

Implementation scope: current single-World SQLite Shop/Auction purchases only.
Exchange settlement stays unchanged. Approved on 2026-10-16: collect as much as
fits in the existing account wallet; keep the remainder claimable.

Invariants: buyer debit, UID transfer, seller revenue and purchase receipt commit
together. A sale never consumes the seller's pending income or credits their
spendable wallet. Collection includes the collector's current pending income in
the same transaction; only its captured prefix is consumed after COMMIT. Replay
and read-only discovery cannot collect again. A durable client intention is
written before send and survives UI reload/re-entry; automatic recovery only
discovers, while explicit Retry may resubmit the original operation.

Storage: additive account revenue table, zero for existing accounts. Historical
sales already credited to wallets stay final; no backfill or double credit. The
ledger uses SQLite signed int64, exposed as a decimal string to avoid JSON/JS
precision loss. Its storage ceiling is INT64_MAX, independent of the much smaller
wallet cap. At that technical limit a sale is rejected atomically; it cannot
silently discard income or overflow into a float. No new gameplay limit or
rounding/clipping is introduced. Collection transfers at most the existing
wallet's free capacity, counting pending income and reserved Yang in its total.

Failure/recovery: any SQL/receipt failure rolls back the entire operation and
leaves runtime pending income untouched. Full wallet/empty revenue reject without
value changes. A missing receipt after transport failure is not failure of the
operation; retain the intention and require an explicit retry. Existing successful
receipts remain readable. Downgrading to direct-credit code after enabling this
feature is unsafe: preserve the ledger and deploy a forward fix/restore a verified
whole-database backup rather than reverting only the code.

Verification will extend purchase, network, load and crash/WAL recovery fixtures,
including offline sale, full wallet, partial collection, rollback, replay,
response loss and restart recovery. Native CEF/input and multi-World behavior are
separate verification boundaries.

The My Shop footer displays the exact decimal revenue and Collect Yang / Retry
collection. Collection uses an adapter-generated `shop-revenue-…` business ID,
independent of browser/native correlation IDs, with the existing scoped local
journal. Re-entry discovers a receipt without automatic mutation; an unresolved
intention blocks replacement. Definitive empty/full rejections release it;
transport/storage failures retain it. Public shop visits/searches expose no
private revenue. Existing receipts from direct-credit sales are not re-applied.
