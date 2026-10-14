# C3 — transactions, persistence and rewards

**Status: Draft — not approved for implementation.**

## Accepted constraints inherited from C1

Critical ItemInstance ownership/custody, trade, equipment, purchase, escrow, Yang spending and receipt outcomes must be atomic and durable before success is acknowledged. Ordinary unclaimed ground drops may be transient World state. Account Yang is realm-wide, not character- or channel-local.

## Topics to decide

1. **Transaction groups:** seller/buyer wallet, offer revision, escrow, ItemInstance custody, inventory capacity, fee/revenue and receipt must not partially commit.
2. **Ground item claim:** World reserves a transient drop; Economy durably grants its UID exactly once; lost reply and duplicate claim reconcile by stable identity. Define drop expiry while claim is pending and handling of orphaned reservations.
3. **Ground Yang:** current local RAM `pending_currency_delta` and ~30s checkpoint are convenient but unsafe as an *uncoordinated* balance source across multiple World Processes. Decide whether tiny gains are (a) immediately recorded, (b) batched with durable grant IDs/acknowledgments, or (c) protected by an explicit single-owner lease and forced handoff checkpoint. Do not assume transient World RAM may be spent cross-process without protocol.
4. **Shop sale income:** choose direct account credit versus separately collectable balance; mail may notify, not serve as the source of money. A collectable balance adds its own transaction, idempotency and overflow/limit rules.
5. **Dungeon rewards:** specify the point at which valuable loot is durably owed, even if the dungeon host crashes before collection.
6. **Database adapter:** SQLite local development can keep one writer; PostgreSQL production uses explicit transaction boundaries, row locking/constraints or optimistic checks, conflict retries and idempotent receipts. Do not assume SQLite serialization equals PostgreSQL semantics.
7. **Recovery:** define backup, WAL/transaction replay, receipts, reconciliation and business invariants after an Economy or World crash.

## Failure cases to test later

Double purchase, partial settlement, duplicate pickup/UID, lost commit reply, grant repeated after World crash, two characters spending the same wallet, failed handoff with unflushed Yang, concurrent seller receipt collection.

## Current code / migration

Preserve the accepted [current persistence policy](../../persistence-policy.md): immediate critical economy writes and account-wallet pending-delta checkpointing. Future migration must explicitly replace only the pieces that cannot safely span World Processes; no current gameplay behavior is changed by this draft.
