# C4 — economy snapshots and World caches

**Status: Accepted — architectural contract (2026-10-14).** Transport, revision granularity and cache refresh implementation remain open; no change to runtime code is authorized.

## Accepted constraints inherited from C1

World combat reads equipment stats from a local view; never call Economy or SQL per hit. Only Economy may commit item/equipment/wallet mutations. Session transitions must not make stale local caches authoritative.

## Accepted C4 architectural decisions (2026-10-14)

- Economy commits mutable ItemInstance/equipment state and returns a **committed change with authoritative revision(s)**. World caches are derived views, not a second writable authority.
- A change to an equipped item's upgrade/affixes/placement can **invalidate dependent state** without requiring players to unequip it. World uses an explicit equipment/combat **dirty/invalidation marker** and recalculates the relevant derived stats from its updated authoritative snapshot at a **safe simulation boundary**. An update indicates what changed; a dirty marker indicates what must be recomputed.
- Coalesce multiple invalidations into one recomputation when possible. Do not call Economy or SQL per combat hit and do not introduce a global event bus solely for cache invalidation.
- **Dirty alone is insufficient across processes.** Reject older revisions, detect gaps/missing facts, and obtain a fresh authoritative snapshot when needed (including session transfers). An item that is no longer validly equipped must not continue affecting combat; reconcile/invalidate before applying subsequent combat steps that depend on it.
- Keep the current local SQLite and `WorldServer.runtime_equipment` behavior until the service boundary is deliberately implemented. Event transport, revision granularity, recovery watermark and exact resync protocol remain open; **architectural acceptance is not implementation approval**.

## Accepted synchronization principles — implementation choices deferred

- **Full snapshot on session entry/transfer:** target World hydrates current inventory/equipment, relevant item revisions, derived combat inputs and account Yang display from Economy before enabling item-dependent gameplay. The snapshot belongs to the new authorized session epoch; it never confers write authority. In cross-World transfer, this must be **coupled with C2's admitted-operation discovery/reconciliation**: a snapshot alone does not cover an older admitted command that can commit after it was read.
- **Versioned updates:** a committed mutation returns new authoritative revision(s). Apply updates in version order; discard duplicates/older facts. If the World detects an unexplained revision gap or misses a notification, request a full authoritative refresh instead of trying to invent the missing state.
- **Dirty, then recompute:** an affected equipment item/slot marks dependent stats and presentation as dirty. Consolidate updates and recompute derived combat state once at the next safe tick boundary from a valid snapshot. Do not perform blocking RPC/SQL in combat.
- **Conflict while mutation is unresolved:** the previous equipment view may remain visible while an operation is pending, but any action relying on an item whose custody/equipment status could change must be gated until its outcome is settled or authoritative state is safely reconciled. An admitted operation with an unknown outcome cannot be treated as rejected just because a snapshot still shows old state. Unrelated combat continues where a safe snapshot exists; if equipment-based combat state cannot be trusted, safely suspend affected actions rather than applying stale stats.
- **Yang display:** account-wallet values shown in the UI may be cached, but Economy always validates actual spending. Account-level wallet/revenue mutations publish revised views or trigger refresh; stale visual balances cannot create credit.
- **Bounded fan-out:** publish minimal committed facts and/or invalidations, coalesce bursts and build snapshots outside the hot combat path. No global event bus, SQL poll on each attack or immediate broad recomputation is required.

### Tests for later implementation

Reordered equip and upgrade replies; out-of-order revision notifications; missed publication on reconnect; stale combat snapshot after item removal; wallet update while changing CH; multiple invalidations in one tick; Economy outage during equip and normal combat.

## Implementation parameters still open

- Exact revision granularity and transport for inventory/equipment/account-Yang views, snapshot/in-flight-operation ordering and asynchronous hydration on a new World.
- Mutations return authoritative committed revisions and facts. Design how World applies changes at a safe simulation boundary, and how to handle out-of-order replies, duplicate events and missed publications.
- Equipment/effects used by combat must not remain valid after authoritative removal/transfer; specify fencing, revision checks and refresh before resuming simulation on another host.
- Multi-character account wallet display: multiple World Processes may cache the same account Yang. They must revalidate spending in Economy; stale UI display can be repaired without granting spend rights.
- Bound publication fan-out, coalescing and snapshot-building cost so many item/economy operations do not stall the World tick.
- Cache failure states: initial hydration failure, Economy outage, reconciliation, partial refresh, and temporarily unavailable inventory actions.

## Failure cases to test later

Equip followed by sale, concurrent alt purchase, delayed event after newer revision, change-CH while mutation pending, reconnect with a stale equipment cache, missed account-wide wallet update.

## Current code / migration

Today `WorldServer.runtime_equipment` caches committed equipment-derived combat stats; WorldDatabase and inventory/currency endpoints refresh after local SQLite commit. Keep this safe current behavior until a deliberate asynchronous boundary is implemented.
