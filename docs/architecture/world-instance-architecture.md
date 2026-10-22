# ADR — World instances, dynamic channels and process topology

- **Date:** 2026-10-14
- **Status:** Accepted architectural direction; local instance/channel behavior is partially implemented. Distributed hosting remains deferred.
- **Applies to:** Mandate of Three realms (e.g. Season and Classic), world simulation, dungeon hosting and future economy boundaries.
- **Does not authorize:** A multi-process rewrite, new runtime workers or unrelated Economy changes. PostgreSQL is already the normal development backend.

## Decision

1. **Use a common MapInstance runtime for public maps, public dungeons (e.g. Demon Tower / DT), and private party dungeons.** An instance owns its players, mobs, ground loot, combat simulation and local lifecycle state. The instance type and admission policy decide who may enter, how it is selected and when it closes. World/realm, map template, instance ID, public channel ID (if any), and hosting process ID are distinct concepts.
2. **Prefer dynamically provisioned, player-visible channels for ordinary public maps.** Start with only the public map instances that are needed. Open additional CH instances on demand for busy maps, expose them for intentional player selection, and drain unused instances before closing them. Do not pre-create a complete copy of every map for every CH. Channel numbering/availability and cross-map stickiness remain product-policy questions; a selected CH is a preference that may require on-demand creation or an explicit unavailable response, not a guarantee of preexisting maps.
3. **Keep a compatible invisible overflow-layer policy possible.** Channels and layers use the same MapInstance placement/lifecycle machinery; they differ in visibility and routing policy. The current product preference is dynamic channels, not a requirement to ship both modes. The player may switch permitted public channels; the server controls layer assignments. Groups should remain together where capacity and access rules permit.
4. **Public dungeons and private dungeons are both hosted instances with specific policies.** Public DT-style entry may be shared among unrelated players, with floor/boss progress tied to a specific run; extra copies open by policy when needed. Party dungeons use reserved access. Neither type should move active players between runs merely to rebalance load. Specify reconnect, lockout, admission, reset and completion rules when building that content.
5. **Scale through a pool of World Processes, not a fixed one-process-per-channel mapping.** A World Process hosts zero or more MapInstances and owns their Godot main-thread simulation. Processes can run on one machine or different machines. A world-level registry/scheduler chooses a host for *new* instances based on player capacity, tick/workload measurements, CPU and memory headroom, and placement constraints (such as party/dungeon affinity). Adding hosts should not change gameplay semantics. Do not rely on a thread-per-map Godot SceneTree model.
6. **Provision, drain and recreate; do not hot-migrate live simulations in the first implementation.** Schedule new instances on hosts with headroom. Stop admitting to an underused instance, allow its players to leave or transfer safely, then reclaim it. Health/heartbeat and ownership leases must prevent two hosts from claiming the same instance; lost hosts need detection and controlled recovery, not assumed seamless continuation.
7. **Separate simulation from realm-wide authoritative economy.** Each realm has one *logical* Economy Service / transaction authority shared by its channels, layers and dungeons. Its Auction House, item ownership/custody, Yang, escrow, Exchange and receipts are not duplicated per World Process. Season and Classic have independently isolated economies and persistence namespaces, although they may share physical infrastructure. Critical operations must commit durably before success/usable item or money is acknowledged, with idempotent request handling and safe retry/recovery.
8. **Local development remains intentionally simple.** The current prototype uses one World Process hosting local MapInstances and PostgreSQL for accounts, profiles and Economy. SQLite remains reference/legacy coverage. This ADR does not imply launching separate services now: PostgreSQL availability alone does not establish cross-World authority, session fencing or cache coherence. Do not share a writable SQLite file across machines or let several Worlds independently own balances.

## Player routing and failure rules

- The authoritative Instance Manager/registry maps `instance_id -> process/host/endpoint`; it is not the map's simulation thread.
- A transfer reserves destination capacity, fences/deactivates the prior gameplay session and hands over a verified player identity/state once. An initial reconnect-based handoff is acceptable; seamless transfer is optional later.
- Handle lost responses, disconnects and process failures without spawning the same live character twice. Economy commands in flight must retain their idempotency and canonical outcome when a player moves.
- Spawn/despawn hysteresis and minimum lifetime prevent instances from flapping around capacity thresholds. Scale based on actual simulation cost (especially dense combat), not player count alone.
- A single overloaded MapInstance is not accelerated by adding hosts; it needs local optimization, population limits, or another player-visible instance as allowed by gameplay.

## Rollout order (not a current implementation task)

1. Preserve current single-process prototype. Normalize instance identifiers and policy vocabulary when adjacent gameplay work actually requires it; reuse the existing instance manager rather than replacing it speculatively.
2. Validate dynamic CH and public/private dungeon UX and capacity with local instances and current smoke/playtests.
3. Specify cross-process host registry, session handoff/fencing and crash/reconnect contracts. Prototype multiple World Processes on one machine.
4. Before cross-process shared economic state, design the realm-wide Economy Executor/Service contract (durable atomic commands, ownership, idempotency, retry); preserve the current single-World PostgreSQL guarantees while designing cross-process ownership explicitly.
5. Add remote hosts, deployment, health and lifecycle monitoring and load-based placement. Do not require Kubernetes or live-instance migration for the first scalable version.

## Open product and engineering choices

Initial local baseline: [MapInstance admission and isolation](../development/local-map-instances.md)
introduced two configured First Region copies in one World, distinct routing/content/
channel/host/realm labels and isolated simulation. Its original SQLite fixture is historical; normal deployment now shares PostgreSQL Economy within the single World. That
finite baseline did not implement dynamic scaling, a CH selector, active-character
handoff, multi-realm database allocation or cross-host ownership.
The local [admission/lifecycle follow-up](../development/instance-admission-lifecycle.md)
adds bounded pending entries, capacity and safe draining/idle retirement; it does
not implement automatic channel scaling or active-character transfer.
Local [PUBLIC/RESERVED access](../development/instance-access-policy.md) now keeps
reserved runs out of public routing and validates server-owned character membership
at reservation and final join. Party/dungeon gameplay and lockout policy are deferred.
The [bounded provisioning gate](../development/bounded-channel-provisioning.md)
can add public copies under explicit map/host limits and recent CPU headroom.
Measured First Region costs keep its production limit at two copies; automatic
growth for that map is not enabled by this implementation.
The [initial channel selector](../development/initial-channel-selection.md) now
exposes an authenticated public catalogue and pre-spawn choice on the existing
transition screen. Joined characters still cannot switch CH through this API.
The separate [local channel transfer](../development/local-channel-transfer.md)
now reserves an already loaded public copy of the same map, runs a cancellable
server countdown, checkpoints and fences the source, then activates the target
once. It carries HP/position/combat options and retains economic receipt recovery.
This remains one-process session state, not cross-host or durable C5 fencing.

- Final player UX: dynamic public CH is preferred; hidden layers are optional, not committed content.
- Per-map versus realm-wide channel numbering, channel persistence across map transitions, and limits/cooldowns for switching.
- Public DT: run lifetime, floor reset/lockouts, access by late joiners, maximum participants, and whether temporary parallel runs are shown as CH numbers.
- Concrete instance size and spawn thresholds, based on tick profiles; public parties/group affinity and PvP/event constraints.
- Exact deployment topology, transport and handshake/security; one shared Economy Service per realm is a *logical authority*, not necessarily one physical single-threaded process.

## Constraints retained from existing project direction

- World/server authority for combat, movement, inventories and economy remains unchanged.
- Soft progression may checkpoint from RAM; critical unique items and money must use durable, immediate atomic transactions.
- Finish existing Shop/Auction R6 and gameplay milestones before speculative infrastructure work.
- This decision supersedes the earlier *fixed invisible overflow-layer preference* in project direction, **not** the working single-process code or the persistence safety policy.
