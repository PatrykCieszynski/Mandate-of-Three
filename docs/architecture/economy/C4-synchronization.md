# C4 — economy snapshots and World caches

**Status: Draft — not approved for implementation.**

## Accepted constraints inherited from C1

World combat reads equipment stats from a local view; never call Economy or SQL per hit. Only Economy may commit item/equipment/wallet mutations. Session transitions must not make stale local caches authoritative.

## Accepted C4 decisions (2026-10-14) — partial acceptance only

- Economy commits mutable ItemInstance/equipment state and returns a **committed change with authoritative revision(s)**. World caches are derived views, not a second writable authority.
- A change to an equipped item's upgrade/affixes/placement can **invalidate dependent state** without requiring players to unequip it. World uses an explicit equipment/combat **dirty/invalidation marker** and recalculates the relevant derived stats from its updated authoritative snapshot at a **safe simulation boundary**. An update indicates what changed; a dirty marker indicates what must be recomputed.
- Coalesce multiple invalidations into one recomputation when possible. Do not call Economy or SQL per combat hit and do not introduce a global event bus solely for cache invalidation.
- **Dirty alone is insufficient across processes.** Reject older revisions, detect gaps/missing facts, and obtain a fresh authoritative snapshot when needed (including session transfers). An item that is no longer validly equipped must not continue affecting combat; reconcile/invalidate before applying subsequent combat steps that depend on it.
- Keep the current local SQLite and `WorldServer.runtime_equipment` behavior until C4 and the service boundary are actually implemented. The specific event transport, revision granularity and resync protocol remain open; C4 remains **Draft**.

## Topics to decide

- Define independently versioned inventory/equipment snapshots and account Yang views, plus how a new World loads them.
- Mutations return authoritative committed revisions and facts. Design how World applies changes at a safe simulation boundary, and how to handle out-of-order replies, duplicate events and missed publications.
- Equipment/effects used by combat must not remain valid after authoritative removal/transfer; specify fencing, revision checks and refresh before resuming simulation on another host.
- Multi-character account wallet display: multiple World Processes may cache the same account Yang. They must revalidate spending in Economy; stale UI display can be repaired without granting spend rights.
- Bound publication fan-out, coalescing and snapshot-building cost so many item/economy operations do not stall the World tick.
- Cache failure states: initial hydration failure, Economy outage, reconciliation, partial refresh, and temporarily unavailable inventory actions.

## Failure cases to test later

Equip followed by sale, concurrent alt purchase, delayed event after newer revision, change-CH while mutation pending, reconnect with a stale equipment cache, missed account-wide wallet update.

## Current code / migration

Today `WorldServer.runtime_equipment` caches committed equipment-derived combat stats; WorldDatabase and inventory/currency endpoints refresh after local SQLite commit. Keep this safe current behavior until a deliberate asynchronous boundary is implemented.
