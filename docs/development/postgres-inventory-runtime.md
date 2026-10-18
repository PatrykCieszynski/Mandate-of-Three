# PostgreSQL P3d — World Inventory delivery and reconciliation

**Opt-in integration component; the live game still uses SQLite.**
`inventory_runtime_postgres.gd` owns Inventory recovery and main-thread delivery
from the [P3a executor](postgres-inventory-executor.md), using the durable identity
and delegated session context from [P3b](postgres-inventory-intents.md) and
[P3c](postgres-inventory-sessions.md). It updates the actual
`WorldServer.update_runtime_equipment()` projection; it is not another stat cache.
Combat continues reading RAM, without PostgreSQL round trips per hit.

## Ownership and admission

One World-thread caller starts the executor and waits for readiness before
handing its exclusive `poll()` ownership to this component. Do not mix other
executor consumers or leave unrelated control jobs outstanding at handover.
Install a verified grant through the privileged P3c owner first, then call
`attach(peer_id, context)`. This is an internal server API, not a client RPC.

The production World session helper verifies connected peer, current character
mapping, current peer on the PlayerResource and the fingerprint of the consumed
Master ticket. The runtime component checks that fingerprint against its captured
context before scheduling or accepting results. PostgreSQL independently checks
account, character and current grant/epoch in each session transaction.
The helper does not authenticate a ticket supplied by a client, issue a grant,
or establish that Master has delivered its latest revocation.

Repeating `attach()` for the identical peer and complete session context is an
idempotent success. It preserves the active command/body, outstanding ticket,
readiness and paused/unknown state without emitting another lifecycle change.
Use explicit `retry()` for paused recovery; a different peer or context still
creates a replacement binding with a new local generation.

At most 64 account bindings exist. Each has one local Inventory workflow and at
most one outstanding executor ticket. A command during recovery/another workflow
is rejected locally with `recovery_required`, not buffered behind it. Independent
accounts can progress in parallel through the existing bounded pool. Discovery
retains at most 32 pending IDs per page; results/snapshots are replaced rather
than accumulated. Executor capacity also bounds retired-but-unconsumed tickets.

## Recovery to ready

`attach()` starts closed for dependent mutations. Repeated World-thread polls:

1. Discover account-wide Inventory intents in bounded pages.
2. Resume pending identities for their original issuing character.
3. Load a session-qualified coherent snapshot.
4. Validate account/character/authority/revision and apply it through the existing
   World equipment/stat watermark guard, then emit a copied `snapshot_applied`.
5. Acknowledge that marker using the backend's pending/freshness barrier.
6. Only after acknowledgement expose `mutations_allowed(peer_id)` and readiness.

A late external item commit between snapshot application and acknowledgement
makes the marker stale. The component repeats discovery/hydration, up to three
repairs, then pauses closed. Snapshot rejection, stale session, storage failure
or uncertain COMMIT likewise pauses closed and emits `recovery_failed`.
It does not force a different authority over the existing World watermark;
cutover must start from a correctly hydrated, coherent owner.

## Command and result flow

`submit(peer_id, operation_id, action, uid, revision, position)` captures the
original body and closes this local Inventory lane. Its `queued` return is only
RAM scheduling. `operation_admitted` is emitted after the P3b durable admission
ACK, not on executor queueing. Pending work resumes using its original ID.

Terminal success or rejection triggers a new authoritative snapshot. World
equipment/stats are reconciled before `operation_finished` publishes the terminal
business result. A rejection repairs the view; a receipt replay is not a new
item mutation. No generic committed-event bus or automatic cross-domain fact
fan-out is introduced by this component.

After storage/COMMIT uncertainty there is no automatic mutation retry. The caller
may explicitly call `retry(peer_id)`: recover pending account work, hydrate and
acknowledge a fresh marker, then discover the current command's original outcome.
If uncertain admission left no durable row, this explicit retry resubmits the
same captured ID/body. If the owner itself was lost, the client must retain that
unacknowledged identity/body; durable discovery cannot enumerate a missing row.
Do not interpret `recovery_failed` as a terminal economic rejection.

Each binding has a local generation in addition to its durable context. Replacing
or detaching it does not cancel SQL or roll back accepted work. Old completions
are consumed but cannot apply stats, emit a snapshot or notify the new peer.
Signal callbacks that detach/replace a binding cannot accidentally acknowledge
or finish the replacement. A stale disconnect only detaches its own peer.

The caller must continue polling while the executor drains to STOPPED, including
after all peers detach. This component never closes active native SQL or joins a
running worker on the simulation thread.

## Integration boundary and evidence

This component is opt-in. The [P3e bridge](postgres-inventory-session-bridge.md)
adds an optional current Master grant owner and native World attach/detach;
[P3f](postgres-inventory-endpoint.md) adds optional endpoint/client correlation,
receipt recovery and private Inventory/public weapon publication. Normal bootstrap
and other economy domains remain to integrate. Callers must consult its gate for dependent
actions; merely constructing the component does not gate a live character.
Handoff with pending Yang, real mixed World/network PostgreSQL traffic and P4
load/soak/cutover remain open. No backend switch or dual writes are enabled.

[P3g cache reconciliation](postgres-inventory-cache-fence.md) now acknowledges
post-command/receipt snapshots too, and consumes trusted account-revision
invalidations with a coalesced floor, bounded repair and RAM-only combat gating.
Future Shop/Storage/Upgrade ports must deliver their committed markers before
dependent gameplay proceeds. Their publishers and distributed transport/missed
idle notifications remain unimplemented; no broader domain activation is implied.

[P3h pending recovery](postgres-pending-recovery.md) now uses session-qualified
pending-only discovery through an account/sequence partial index. Historical
discovery and original-ID outcome/receipt lookup remain available explicitly,
without pruning terminal records. This removes history enumeration from runtime
recovery; it does not complete P4 storage/load/operational acceptance.

Run `tools/postgres/run_readiness.py --suite inventory-runtime` on owned fixtures.
The fixture uses real PostgreSQL workers, SceneTree physics and production World
combat projections, with peer maps explicitly seeded. Existing native session
tests separately verify the new fingerprint helper on real authenticated sockets;
that does not claim a full PostgreSQL Gateway/Master/World login flow.
See [P3d evidence](../evidence/postgres-p3d/README.md).
