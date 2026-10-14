# C5 — handoff, sessions and failure recovery

**Status: Draft — not approved for implementation.**

## Accepted constraints inherited from C1 and world topology

A CH, overflow layer, public dungeon and private party dungeon are MapInstances hosted by World Processes, possibly on different machines. One economy authority serves the entire realm, independent of instance placement. A character must not have two active authoritative gameplay sessions.

## Topics to decide

- Session ownership lease/epoch, who issues it, renewal and revocation; define when Economy refuses an old World's new commands.
- Safe transfer: destination reservation, suspend/fence source gameplay, checkpoint progression/pending Yang as required by C3, hydrate inventory/equipment on target, then activate exactly one session.
- Handling of commands accepted just before a session epoch changes: result lookup and reconciliation instead of speculative retry with a new ID.
- Transfer timeouts, disconnect/reconnect, client reconnect-based handoff as first version, and fallback when target World is lost.
- Instance/process/host failure: distinguish losing transient mob/drop state from durable item/currency/receipt state. Define recovery/cleanup and what player must observe.
- Economy outage while combat continues: degrade gracefully; no automatic creation or use of uncommitted spendable items.
- Shutdown/backup coordination across services and how to drain durable commands without freezing a simulation tick.
- Public DT-style runs and private dungeons: retained access/rejoin window, run closure, resets/lockouts and rewards after host failure.

## Failure cases to test later

Peer reuse, split-brain World claims, source death during handoff, target death after reservation, delayed response from prior session, crash after durable loot claim but before ground-drop deletion, Economy restart during a purchase.

## Current code / migration

Current single-process instance lifecycle, session admission and SQLite graceful save remain authoritative. No cross-process transfer, realm-wide session coordinator or failure failover is asserted to exist by this document. See [world instance architecture](../../world-instance-architecture.md).
