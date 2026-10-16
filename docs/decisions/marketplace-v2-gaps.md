# Shop / Auction: accepted future behavior versus `shop` today

**Status:** Decision delta / implementation backlog, recorded 2026-10-14. **No code changed.** This document reconciles [Economy C3](../architecture/economy/C3-transactions.md) with the open [Marketplace PR #1](https://github.com/PatrykCieszynski/Mandate-of-Three/pull/1). The PR implementation is a verified prototype milestone, **not** an implementation of every subsequently accepted Economy V2 decision.

| User-facing behavior | `shop` branch today (PR #1) | Accepted target / next implementation |
| --- | --- | --- |
| Withdraw from player shop | `MarketStoreSqlite.cancel_offer` removes offer and moves item to `account_claim` without requiring ordinary Inventory capacity | Withdraw moves item back to character Inventory and deletes offer **atomically**; insufficient space rejects the complete withdrawal |
| Remove price / negotiation-only listing | `list_item` and `edit_offer` require `price > 0` | Item may stay publicly listed with **no fixed price**, explicitly labelled *Do negocjacji / Offer Only*, not free/zero-Yang buy-now |
| Buyer offers and counteroffers | Not implemented | **Deferred.** Players agree out of band and privately trade after seller withdraws the UID from Shop custody. No bid ledger or reserved buyer Yang now |
| Sale revenue | `purchase` credits seller `account_wallets` immediately | Credit the seller's independent account `claimable_yang` ledger, collect manually in Shop UI; never lose earnings because the spendable wallet is full |
| Offline shop continuity | Shop / custody / purchase available without active seller session | Preserve. Existing listings and sales do not block safe CH changes; only active character-originated shop interactions are gated |
| Atomicity / item custody | SQLite transaction and receipt, buyer inventory fit validation, one UID winner | **Preserve** the existing safety guarantees while changing UX and ledger model |

## Integration decision

**Implementation update, 2026-10-16:** the table above records the historical
PR #1 baseline. Capacity-backed withdrawal and Offer Only are now integrated.
The current Shop revenue slice adds the separate ledger and manual collection;
the user approved partial collection up to existing wallet capacity, retaining
all remainder. See [runtime policy and recovery](../development/shop-revenue.md).
Exchange keeps its own settlement rules. Other sale sources and future cap
changes remain separate decisions.

Do **not** silently combine these product changes with a mechanical merge of PR #1. First update `shop` with current `main`, re-run its existing tests, then either:

1. Merge the currently verified Marketplace vertical slice and implement these differences in dedicated follow-up PR(s); **or**
2. Hold PR #1 until these differences are implemented and verified, if the release baseline must match the newest product spec.

The current recommendation is **option 1 for internal development**: preserve a reviewable baseline, with no public-alpha claim until the new shop behavior and safety tests pass. A user-facing launch gate is separate from a code integration gate.

### Acceptance scenarios for follow-up

- Full inventory → shop withdrawal rejected with UID and offer unchanged; free slot → item placed and listing removed together; same item cannot be traded in two places.
- Removing the fixed price leaves a visible negotiable listing; attempts to buy it for 0 Yang or via the previous fixed-price RPC fail.
- Sale while seller offline → UID moves exactly once; seller receives claimable income exactly once; no hidden direct-credit duplication.
- Claimable Yang overflow/partial-claim policy must be decided before implementing the claim action. Preserve the full amount in the ledger whatever UI policy is chosen.
- Existing buy vs edit vs cancel races, stale revisions and request replay still behave correctly.

**Known open choices:** numerical caps, partial-claim policy, future player-to-player offer system, seller contact UI, and whether a player can actively advertise items while in dungeon/combat. These should not be inferred from the current SQL model.
