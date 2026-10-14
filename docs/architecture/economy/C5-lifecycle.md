# C5 — handoff, sessions and failure recovery

**Status: Draft — not approved for implementation.**

## Accepted constraints inherited from C1 and world topology

A CH, overflow layer, public dungeon and private party dungeon are MapInstances hosted by World Processes, possibly on different machines. One economy authority serves the entire realm, independent of instance placement. A character must not have two active authoritative gameplay sessions.

## Proposed completion rules — multi-World handoff and outages (pending final review)

- **Session authority:** prefer one active character per account *within a realm* (cross-realm login policy remains open). Gateway/realm session authority issues an owner/lease/monotonic epoch for each active character; Economy admission validates the current authorized actor/session context and fences newly submitted commands from stale Worlds. Process/instance IDs are not themselves proof of authority.
- **Controlled handoff (no live-map migration):** reserve a target MapInstance and confirm it is available; pause new source gameplay/economy intents; settle required pending Yang and soft progression checkpoints; revoke/fence source authority; load target snapshots and reconcile accepted economic operations; activate exactly one target session; then release the source. Each stage must be retryable/observable; failed destination activation must allow controlled rollback, retry or reconnect, never dual activation.
- **In-flight economics:** commands admitted under an old epoch may complete. New World can retrieve their terminal outcome using original `operation_id` or safely resync authoritative revisions. Epoch fencing applies to new admissions, not a retroactive rollback of committed transactions.
- **Server-authorized CH change, not client-triggered teleport:** source World / session authority checks transition eligibility *before* fencing. Deny or postpone while in combat/recently damaged (a tunable combat cooldown), with open direct trade, active shop editing / other exclusive item interaction, or with mutually dependent economic work that has not been reconciled. An **approximately five-second delay after a completed direct trade or other sensitive transaction** is a gameplay/configuration candidate, **not a substitute for checking pending operations or a durability guarantee**; the historical Metin2 value is not relied on here.
- **Character-scoped economic admission gate:** on approved transfer preparation, stop accepting new inventory/trade/shop-edit/other character-originated economic mutations from this old World session and close incompatible interaction UIs, without stopping the realm Economy Service or blocking unrelated accounts. Existing posted shop listings/offline sales may continue under Economy authority; only World-originated character access is gated. If preparations fail before authority moves, safely reopen admissions on the still-active source session.
- **Drain and freeze are distinct:** after the gate, settle required pending Yang grants, retrieve/reconcile outcomes of previously admitted character commands and checkpoint needed progression. A fixed cooldown alone cannot prove all SQL/network commits finished. Reserve destination capacity and fence the source epoch before target activation. If an already-admitted command finishes late, the destination observes the authoritative revisions/receipts; it must not issue a duplicate with a new operation ID.

- **Failure handling:** when a World or host dies, leases expire/are revoked and the gateway restores one authorized login path. Item/currency/receipts survive in Economy; transient mobs/ordinary ground drops and uncheckpointed soft progression/Yang may not. Protected dungeon reward manifests survive; continuous combat/dungeon progress is **not** promised. Do not expose the same live character in two instances while recovering.
- **Economy outage:** leave World movement/combat operating on a safe cached snapshot; economic actions fail closed or remain pending. Never fabricate committed success. On recovery, query outcomes and rehydrate before re-enabling item-dependent mutations.
- **First deployment stage:** controlled client reconnect to the target World is acceptable. Host discovery, leases, health checks and placement can first run with multiple processes on one machine; moving hosts to other machines is a later deployment step. No hot migration, Kubernetes or distributed transaction spanning World and Economy is assumed.

### Tests for later implementation

Source fails before source fencing; destination fails after reservation; lost activation ACK; replayed session epoch on another host; stale World submits a new purchase; admitted purchase finishes after CH switch; pending Yang checkpoint fails; Economy unavailable during reconnect; dungeon host dies with committed/unclaimed manifest.

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
