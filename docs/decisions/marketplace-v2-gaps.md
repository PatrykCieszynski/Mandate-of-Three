# Marketplace decisions and remaining product choices

The 2026-10-14 review compared the original `shop` / PR #1 prototype with
[Economy C3](../architecture/economy/C3-transactions.md). That branch comparison
is historical. Marketplace/Auction/Exchange and PostgreSQL are now integrated;
this document is not a pending instruction to merge PR #1 or repeat its rollout.

## Accepted behavior now implemented

| Behavior | Current contract |
| --- | --- |
| Withdraw a listing | Transfer its UID into character Inventory and remove the listing atomically; insufficient capacity leaves both unchanged |
| Offer Only | A price-free negotiable listing is distinct from a free/zero-Yang purchase; there is no buy-now action without a fixed price |
| Seller revenue | A sale atomically debits the buyer, transfers the UID and credits separate account claimable revenue, including its durable outcome |
| Manual collection | Collect what fits in the current account wallet, counting pending income/reservations; retain the remainder |
| Offline shops | Listings and settlement do not require an online seller; offline sales do not mutate an unrelated live wallet cache |
| Custody and retry | Preserve ownership, revisions, atomic capacity, one UID winner and receipt-backed recovery after a lost response |

Partial collection was approved on 2026-10-16. See
[revenue and recovery](../development/shop-revenue.md),
[current persistence](../architecture/persistence-policy.md) and
[PostgreSQL deployment](../development/postgres-full-state.md).
Exchange retains its separate reservation/order/settlement rules.

## Explicitly deferred or unresolved

Buyer offers/counteroffers and their escrow are deferred. Players can negotiate
out of band and trade after withdrawal; this does not establish an implemented
private Trade system or authorize a bid ledger now.

Future numerical caps, additional revenue sources, seller-contact UI and rules
for actively advertising while in dungeon/combat need maintainer decisions.
They must not be inferred from the SQL model or the original PDFs. Cross-World
settlement/cache coherence is separate from the implemented single-World flow.

## Regression contracts

- Full Inventory rejects withdrawal without changing offer or UID custody.
- Removing a fixed price cannot be bypassed by a stale-price or zero-Yang buy.
- An offline sale transfers the UID and grants claimable income exactly once.
- Partial collection preserves the remainder and includes pending income.
- Buy/edit/cancel races, stale revisions and receipt replay remain safe.

These are protected behaviors, not a new implementation backlog. Select current
verification commands using the [testing policy](../development/testing.md).
