# C3 — transactions, persistence and rewards

**Status: Draft — not approved for implementation.**

## Accepted constraints inherited from C1

Critical ItemInstance ownership/custody, trade, equipment, purchase, escrow, Yang spending and receipt outcomes must be atomic and durable before success is acknowledged. Ordinary unclaimed ground drops may be transient World state. Account Yang is realm-wide, not character- or channel-local.

## Accepted C3 decisions (2026-10-14) — partial acceptance only

- **Ordinary mob-ground Yang may use bounded, batched accrual**, as in the current prototype's positive `pending_currency_delta` and approximately 30-second checkpoints. A sudden World Process crash may lose only the still-uncommitted portion of this **soft grinding income**; this accepted risk does **not** apply to already committed balances or item/trade/Shop outcomes.
- **Critical spending and economic mutations must settle atomically.** A purchase, upgrade, trade, Exchange order or other meaningful spend must include any relevant pending income in its authoritative transaction (or first safely reconcile it), check funds and commit the item/currency/receipt changes together. Uncommitted client-visible farming income cannot be used to bypass a durable balance check.
- **Before cross-process handoff**, outstanding locally owned Yang deltas must be safely committed/reconciled and the original earning authority fenced; never transfer and then allow both old and new World Processes to flush the same accrual. A failed required checkpoint means the handoff cannot be confirmed as successful; specify recovery and retry when designing C5.
- Account Yang belongs to the realm Economy authority, not to CH/instance/World. The final multi-process batching protocol must have stable batch/grant identities, acknowledgements and duplicate-apply prevention, or another **equivalently safe single-writer/lease settlement mechanism**. The exact protocol and threshold are deliberately **not approved yet**.
- **Shop/Auction seller revenue is credited to an account-scoped, realm-scoped `claimable_yang` balance, not directly to spendable Yang.** The buyer's debit, item custody/ownership change, offer settlement, seller's claimable credit and idempotent receipt must commit **atomically**. Offline sellers and sellers playing on another World Process require no local wallet mutation to settle a sale. A sale is final after COMMIT even before the seller manually claims its revenue.
- **Claim seller revenue from the My Shop/market panel.** An authenticated `ClaimShopRevenue` command atomically moves the claimed amount from `claimable_yang` to the shared account wallet, with a stable `operation_id` and receipt. The same funds cannot be claimed twice, spent before claiming, or counted as both pending and spendable. The panel may aggregate the balance while keeping itemized sales history separately. In-game mail may notify the player but must not be the monetary ledger or create one mail per sale.
- Claim limits, wallet overflow/max-balance policy, full versus partial claim, and whether Auction and other sale sources use the exact same pool remain open for C3 implementation design. This is **future-state design**: current Shop/Exchange settlement logic and local SQLite runtime are not changed by this document.
- Local SQLite single-writer and existing `pending_currency_delta` behavior remain unchanged. This design does not approve a premature worker/process migration.

## Accepted protected-loot direction — selected parameters remain open

**Motivation:** keep the familiar physical ground-loot experience and avoid a second inventory full of uncollected trash. A persisted reward manifest is only for selected high-value encounters/reward categories, not every mob or every item. Exact selection/rarity threshold is open. The chosen gameplay rule is not an entitlement to collect everything that drops.

| Encounter type | Ground pickup rights | Fallback for unclaimed *eligible protected* loot |
| --- | --- | --- |
| Solo dungeon | Initially exclusive to the solo player; ordinary pickup works | Player's bounded, time-limited reward stash |
| Party dungeon | Initially assigned per player using a later-defined gameplay policy; assignment expires after **approximately 60 seconds** (initial configurable policy), then any eligible party member may collect | At run closure/crash recovery, unclaimed protected loot becomes claimable from the **run's designated party leader's** time-limited stash |
| Ordinary mobs/Metins | Existing temporary ownership and eventual public pickup policy | No stash; unclaimed ground drops expire normally |
| Major world boss | Design separately, because public ownership release may conflict with fallback entitlement | Not yet decided |

- Do not bind a protected *party* drop irrevocably to its initial assigned player while also allowing other members to claim it. Its manifest instead records the current claim rights/state; the **first valid claim wins atomically** and precludes a stash copy.
- Snapshot the designated party leader for any fallback at reward-manifest creation, so party-leadership changes or party dissolution do not silently redirect rights. Whether leader-only fallback is fair and which exceptional rewards qualify remains a gameplay/product consideration, not a generic Economy ownership rule.
- The fallback stash has a **12-hour claim window** after the reward becomes available in the stash (normal run closure or crash recovery). Opening the stash must not implicitly consume other rewards, and an inventory-full claim must leave the reward pending without duplication. Exact size/caps and notification UX remain to be designed.
- Ordinary/low-value drops should **not** fill the stash. A manifest can describe selected guaranteed/valuable rewards; all other drops continue as transient MapInstance entities with the existing expiring pickup rights.
- A selected protected encounter must durably register its manifest/UIDs and claim policy **before exposing protected ground drops**. Claims, transition to a fallback stash and expiry are mutually exclusive durable state transitions: `on_ground -> claimed_by_character` **or** `on_ground -> stash_claimable -> claimed_by_character / expired`; never grant a second UID on recovery. A host crash with a committed manifest but no live instance can trigger fallback without silently consuming the rewards.
- The *award allocation formula* (damage contribution, party contribution, random distribution), the scope of "eligible party", loot visualization, and detailed dungeon run lifecycle belong to gameplay/dungeon design, not this economic durability contract.

**Status of this section:** accepted direction for selected valuable dungeon rewards: physical drops, solo-owner fallback, party loot becoming shareable after approximately one minute, unclaimed protected party rewards going to the designated leader, and a 12-hour stash expiry. The actual protected-item eligibility/caps, exact timer behavior and world-boss loot policy remain **open**. No change to current gameplay is authorized by this draft.

## Topics to decide

1. **Transaction groups:** seller/buyer wallet, offer revision, escrow, ItemInstance custody, inventory capacity, fee/revenue and receipt must not partially commit.
2. **Ground item claim:** World reserves a transient drop; Economy durably grants its UID exactly once; lost reply and duplicate claim reconcile by stable identity. Define drop expiry while claim is pending and handling of orphaned reservations.
3. **Ground Yang implementation:** batching/controlled loss, atomic spending and handoff reconciliation are accepted above. Still decide exact batching protocol (stable grant/batch IDs or equivalent lease), replay-safe acknowledgment, bound on pending deltas, crash and failed-handoff recovery, and how the UI represents spendable funds before settlement.
4. **Shop sale income:** separately collectable account-level balance and atomic manual claim are accepted above. Still decide wallet maximum/overflow, partial vs full claim, aggregation across market surfaces, UI synchronization and receipt retention.
5. **Dungeon rewards:** implement the accepted solo/party direction only in a later gameplay milestone. Still decide protected drop eligibility/caps, exact one-minute grace semantics, crash-before-manifest vs crash-after-manifest, claim expiry and recovery of live ground drops.
6. **Database adapter:** SQLite local development can keep one writer; PostgreSQL production uses explicit transaction boundaries, row locking/constraints or optimistic checks, conflict retries and idempotent receipts. Do not assume SQLite serialization equals PostgreSQL semantics.
7. **Recovery:** define backup, WAL/transaction replay, receipts, reconciliation and business invariants after an Economy or World crash.

## Failure cases to test later

Double purchase, partial settlement, duplicate pickup/UID, lost commit reply, grant repeated after World crash, two characters spending the same wallet, failed handoff with unflushed Yang, concurrent seller receipt collection.

## Current code / migration

Preserve the accepted [current persistence policy](../../persistence-policy.md): immediate critical economy writes and account-wallet pending-delta checkpointing. Future migration must explicitly replace only the pieces that cannot safely span World Processes; no current gameplay behavior is changed by this draft.
