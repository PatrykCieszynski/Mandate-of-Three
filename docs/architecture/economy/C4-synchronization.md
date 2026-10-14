# C4 — economy snapshots and World caches

**Status: Draft — not approved for implementation.**

## Accepted constraints inherited from C1

World combat reads equipment stats from a local view; never call Economy or SQL per hit. Only Economy may commit item/equipment/wallet mutations. Session transitions must not make stale local caches authoritative.

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
