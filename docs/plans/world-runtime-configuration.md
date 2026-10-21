# World runtime configuration and capacity budgets — W0/W6 addendum

**Status:** W0 audit authorized 2026-10-21; configuration implementation remains proposed. PostgreSQL local cutover is complete. See the [current limit audit](world-w0-limit-audit.md) for actual ownership and admission gaps. This document is **not** authorization to raise runtime limits, refactor World or enable a second live World process.

**Parent roadmap:** [World Server optimization — W0–W7](world-server-optimization.md). This is a focused supplement, **not a replacement roadmap**. Follow the parent plan's review, measurement, parity and rollback rules.

## Purpose

Make operational limits discoverable, documented and consistent. A World may have many connected players while only a small fraction submit economic work. The connection/player ceiling, per-session bindings, concurrent operations, PostgreSQL workers and bounded queues are **different resource dimensions**. Avoid a hidden Inventory binding ceiling that rejects an otherwise accepted World player.

The existing `InventoryRuntimePostgres.MAX_BINDINGS = 64` and `SellerRuntimePostgres.MAX_ACTIVE = 64` have different meanings. The former caps attached account Inventory bindings; the latter caps active seller commands, including detached accounts with unresolved outcomes. Neither means 64 PostgreSQL connections or proves a hardware/physics capacity limit. Existing World PG composition uses Inventory 2, wallet 1, NPC 1, Storage 1, ground 1 and marketplace 2 native workers; Master owns a separate grant worker. Preserve bounded executor behavior until measurements justify a change.

## 1. Single-World capacity and ownership

| Resource | Desired policy | Exhaustion semantics |
| --- | --- | --- |
| World connected sessions | One configured per-process admission ceiling, eventually informed by W6 real-client benchmarks | Reject new admission **before** promising a usable session; do not evict an existing player |
| Inventory and Wallet account bindings | Capacity compatible with the admitted-session budget; verify their full lifecycle and detached/recovery semantics | No surprise lower independent ceiling for a normally admitted player; preserve pending recovery/fencing |
| Seller/Exchange active commands | Separate bounded concurrency budget; not tied 1:1 to online-player capacity | Explicit backpressure and receipt-first recovery, not lost or duplicated committed commands |
| Native PostgreSQL workers | Bounded pool per domain; connection count is **not** online-player count | A saturated pool rejects/defers safely; never create one connection per player |
| Native queue slots | Small, bounded capacity per worker, counted according to the actual executor contract | No unbounded queue growth or loss of accepted/uncertain work |
| Pending/detached operation recovery | Independently accounted bounded resource; document retention until durable outcome resolution | Never discard unresolved effects to admit a fresh player |
| MapInstance / channel | Separate per-instance budget only if needed and measured | Must remain subordinate to the World process ceiling |

Distinguish **registered accounts**, **synthetic actors**, **attached session bindings**, **real network clients**, and **concurrent SQL operations** in code, metrics and evidence. Do not infer 500-player capacity from a fixture with 500 IDs.

A session cap alone cannot guarantee CPU or memory safety under dense combat; retain separate budgets/admission for actual active work. W0 must inventory all owner-specific ceilings before deciding whether to keep, derive, or eliminate a redundant binding limit.

## 2. Configuration approach

Use a validated, server-only **immutable runtime settings object** constructed at startup from a private config file. Do not add a mutable global singleton holding arbitrary state. Keep parsing, defaulting, cross-field validation and reporting centralized; pass the validated budgets explicitly to each owner. Invalid or contradictory settings fail startup rather than being silently clamped. Keep existing safe defaults until benchmark-backed acceptance and do not implement hot-reload for worker counts or session ceilings in this package.

**Illustrative proposed config; these keys are not all implemented today and the numbers below are examples, not approved production defaults:**

```ini
[world]
# Maximum concurrent admitted clients in this World process, not per map.
# Inventory/Wallet attachment must support every accepted session.
max_players=500

[economy]
# Maximum simultaneous Seller/Marketplace operations, including commands
# paused for receipt discovery after a disconnected client.
# This is NOT the number of shops, accounts or database connections.
max_active_market_operations=64

[postgresql]
# Native Inventory workers; each owns one PG connection, shared by many accounts.
inventory_workers=2

# Native pool for Seller/Marketplace, Exchange and Auction execution.
# More workers increase database concurrency; they do not raise player capacity.
marketplace_workers=2

# Pending work budget PER native worker (confirm exact queued/in-flight semantics
# against the executor before promoting this to a public configuration option).
# Saturation must preserve domain-specific rejection and recovery contracts.
queue_capacity_per_worker=2
```

Comments should explain **non-obvious semantics, units, operational effects and dependencies**, not restate obvious variable names. Maintain one complete, versioned, commented sample config in the repository once supported keys are finalized; document defaults and permitted ranges alongside validation. Never include DSNs, passwords, tokens, internal account/identity data or other secrets in public status. Existing server-only environment-based PG credentials remain separate.

### Which constants become settings?

Only tunable deployment/resource budgets supported by an owning component and validation. Keep gameplay rules, SQL invariants, UID/receipt semantics and security-critical limits in code unless there is a concrete safe operational reason to expose them. Do not indiscriminately move every constant into configuration.

## 3. W0 audit before implementation

Inventory actual limits on **current main** and record for each: constant/key; owner and path; value/default; units; resource dimension; measured rationale versus provisional guard; admission/error semantics; cleanup/recovery interaction; related budgets; decision to keep constant, derive from `max_players`, expose as config or replace with a stronger admission rule.

Initial search targets (verify current locations): Inventory `MAX_BINDINGS`, Seller `MAX_ACTIVE`, Wallet/Storage/NPC/Ground admission, executor pool/queue sizes, session/ticket limits, server peer admission, per-map caps and snapshot/auction read limits. Do not equate a page-size cap or a security fence with a World player limit.

W0 must explicitly verify whether binding iteration/polling is O(online sessions) each frame, how much memory a typical/full Inventory snapshot consumes and when disconnected/paused owners release resources. Do not assume the physics experiments selected the value 64 without evidence.

## 4. Acceptance and benchmarking

1. **Contract tests:** reject `max_players + 1` before issuing a usable handoff; Inventory/Wallet attach at configured session capacity; logout/relog releases/reuses resources without stale authorization or lost pending state. Test invalid cross-field config and fail-closed startup.
2. **Synthetic runtime binding scaling:** measure 24 → 64 → 128 → 256 → 500 (higher only if safe), with empty and representative full Inventories, gradual arrival and login bursts. Log latency, CPU/RSS, binding memory, queue depth, per-frame poll/projection costs, disconnect/drain and unresolved recovery.
3. **Representative Economy workload:** many accounts, mostly low-frequency independent actions; Auction search, shop browse/buy (including five purchases from one seller), Exchange, aggregated grinding Yang and loot/relog. Count both attempted and successful actions, terminal refusal and original-ID recovery. Keep the existing intentionally saturated Economy stress/soak as a **separate test case** with reusable fixtures/audits where practical.
4. **W6 true-client capacity:** use real Gateway → Master → World connections, input/RPC/replication, combat/AI and density; distinguish bots from synthetic bindings. Follow W6 ramp and same-build repeated baseline rules, with p50/p95/p99 tick and operation tails, network bytes and headroom. Only this gate supports a connected-player capacity claim.

Large workloads remain opt-in, not default CI. Never hardcode environment-dependent performance thresholds into deterministic CI. Maintain rollback by retaining accepted defaults and limiting each implementation PR to a measurable change.

## 5. Placement within existing roadmap

- **W0:** audit ownership and existing ceilings; agree capacity model and documented config contract; introduce central validated settings only in a separate reviewable implementation PR.
- **W1:** profile active-session/binding overhead, polling, snapshot copying, login/relog and queue saturation alongside physics and replication costs.
- **W6:** exercise chosen session ceiling with real connected clients, representative Economy/combat mix and gradual scaling; adjust defaults only with measured headroom.
- **W7:** review capacity evidence and decide deployment values / rollback, not automatic promotion.

The Economy migration's P4 stress/recovery and clean soak, import and cutover gates remain independent and should finish first. This document changes no runtime behavior and does not promise a 500-player World.
