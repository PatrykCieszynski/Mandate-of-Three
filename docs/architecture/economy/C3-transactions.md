# C3 — transactions, persistence and rewards

**Status: Draft — not approved for implementation.**

## Accepted constraints inherited from C1

Critical ItemInstance ownership/custody, trade, equipment, purchase, escrow, Yang spending and receipt outcomes must be atomic and durable before success is acknowledged. Ordinary unclaimed ground drops may be transient World state. Account Yang is realm-wide, not character- or channel-local.

## Accepted C3 decisions (2026-10-14) — partial acceptance only

- **Ordinary mob-ground Yang may use bounded, batched accrual**, as in the current prototype's positive `pending_currency_delta` and approximately 30-second checkpoints. A sudden World Process crash may lose only the still-uncommitted portion of this **soft grinding income**; this accepted risk does **not** apply to already committed balances or item/trade/Shop outcomes.
- **Critical spending and economic mutations must settle atomically.** A purchase, upgrade, trade, Exchange order or other meaningful spend must include any relevant pending income in its authoritative transaction (or first safely reconcile it), check funds and commit the item/currency/receipt changes together. Uncommitted client-visible farming income cannot be used to bypass a durable balance check.
- **Before cross-process handoff**, outstanding locally owned Yang deltas must be safely committed/reconciled and the original earning authority fenced; never transfer and then allow both old and new World Processes to flush the same accrual. A failed required checkpoint means the handoff cannot be confirmed as successful; specify recovery and retry when designing C5.
- Account Yang belongs to the realm Economy authority, not to CH/instance/World. The final multi-process batching protocol must have stable batch/grant identities, acknowledgements and duplicate-apply prevention, or another **equivalently safe single-writer/lease settlement mechanism**. The exact protocol and threshold are deliberately **not approved yet**.
- Local SQLite single-writer and existing `pending_currency_delta` behavior remain unchanged. This design does not approve a premature worker/process migration.

## Topics to decide

1. **Transaction groups:** seller/buyer wallet, offer revision, escrow, ItemInstance custody, inventory capacity, fee/revenue and receipt must not partially commit.
2. **Ground item claim:** World reserves a transient drop; Economy durably grants its UID exactly once; lost reply and duplicate claim reconcile by stable identity. Define drop expiry while claim is pending and handling of orphaned reservations.
3. **Ground Yang implementation:** batching/controlled loss, atomic spending and handoff reconciliation are accepted above. Still decide exact batching protocol (stable grant/batch IDs or equivalent lease), replay-safe acknowledgment, bound on pending deltas, crash and failed-handoff recovery, and how the UI represents spendable funds before settlement.
4. **Shop sale income:** choose direct account credit versus separately collectable balance; mail may notify, not serve as the source of money. A collectable balance adds its own transaction, idempotency and overflow/limit rules.
5. **Dungeon rewards:** specify the point at which valuable loot is durably owed, even if the dungeon host crashes before collection.
6. **Database adapter:** SQLite local development can keep one writer; PostgreSQL production uses explicit transaction boundaries, row locking/constraints or optimistic checks, conflict retries and idempotent receipts. Do not assume SQLite serialization equals PostgreSQL semantics.
7. **Recovery:** define backup, WAL/transaction replay, receipts, reconciliation and business invariants after an Economy or World crash.

## Failure cases to test later

Double purchase, partial settlement, duplicate pickup/UID, lost commit reply, grant repeated after World crash, two characters spending the same wallet, failed handoff with unflushed Yang, concurrent seller receipt collection.

## Current code / migration

Preserve the accepted [current persistence policy](../../persistence-policy.md): immediate critical economy writes and account-wallet pending-delta checkpointing. Future migration must explicitly replace only the pieces that cannot safely span World Processes; no current gameplay behavior is changed by this draft.
