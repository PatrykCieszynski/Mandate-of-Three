# World technical candidates — deferred backlog

**Status:** Discussion notes (2026-10-18), **not authorization to implement**. Do not mistake ideas from Quantum Core X or historical experiments for running guarantees. The current game uses one World Process and SQLite; opt-in PostgreSQL Economy work is tracked separately.

**Goal:** Keep useful ideas discoverable without starting another infrastructure project. Implementation requires separate, measured, reviewable PRs.

| Topic | Priority / trigger | Canonical plan |
| --- | --- | --- |
| Simpler World/server physics | **High technical priority** after the existing Economy/SoC gate | [World optimization W0–W4](world-server-optimization.md) |
| Plugin API | **Separate design/contract review**, only if real extension use cases justify it | This backlog |
| Redis / Valkey | **Evaluate with multi-World design**; not required for local channels | [World topology ADR](../architecture/world-instance-architecture.md) |
| AOI: grid vs quadtree | **Benchmark after physics optimization** | [World optimization W5–W6](world-server-optimization.md) |
| Packet codec generators | **Later**, after the active wire contract stabilizes | This backlog |

## Physics — already covered

[World Server optimization W0–W7](world-server-optimization.md) contains the baseline evidence, player movement candidate, Terrain3D/combat parity, conditional mob optimization, AOI and true-client load gates. **Do not duplicate or supersede it.** Mob pursuit should remain simple; do not add navigation, mob–mob collisions or a GDScript all-entity collision index without profiling. Begin from W0 on the current accepted code, not the old experimental branch.

## Plugin API — review the contract first

**Candidate:** Trusted, first-party extensions with narrowly defined hooks and capabilities; possible cases include GM commands, timed events, special boss/dungeon rules and diagnostics. Existing Godot scenes, Resources and composition may already be sufficient.

A separate design review should establish:
- Two real use cases, a minimal hook catalog, registration and lifecycle (load, failure, shutdown).
- Thread affinity and execution budgets: only the authoritative World thread mutates simulation/SceneTree state. No arbitrary asynchronous plugin mutation.
- Restricted capability context; Economy and session changes must use existing authenticated application commands and transaction boundaries, never direct wallet/custody/receipt edits.
- Hook ordering, error containment, tests for failing extensions and a strategy for substitutable dependencies.

**Non-goals:** Untrusted mods, hot reload, a global event bus, a new DI framework or extension access to raw network packet handlers by default. Reference ideas: [Quantum Core X PluginExecutor](https://github.com/MeikelLP/quantum-core-x/blob/main/src/Core/PluginExecutor.cs) and [plugin contracts](https://github.com/MeikelLP/quantum-core-x/tree/main/src/CorePluginAPI/PluginTypes); inspiration, not code to transplant.

**Gate:** Approve a small API proposal with real examples and preserved ownership/security constraints before any framework code.

## Redis / Valkey — optional shared projections

The accepted [World topology ADR](../architecture/world-instance-architecture.md) assigns authoritative host/instance routing to its registry/manager, and durable economic state to one logical Economy authority. Before adding Redis, enumerate actual cross-process reads and messages, then compare direct Master/Gateway communication and PostgreSQL where appropriate.

**Potential uses:** TTL-backed presence or host lookup projections, short-lived noncritical status, cache invalidation notices and best-effort fan-out. Distinguish process-local in-memory caches from shared data.

**Safety:** Specify the writer/owner, TTL, epoch/version, invalidation and Redis-loss behavior for each key. Redis must not own inventory, Yang, custody, receipts, session fencing or durable admission. Pub/Sub loses messages when subscribers are offline; critical transitions require authoritative reread or another explicitly durable mechanism. Stale cache entries must never permit two active session owners or create a new per-hit network dependency.

**Gate:** A multi-World experiment demonstrates a concrete latency/operations benefit over the no-Redis baseline; verify restart, stale-data and outage paths. Docker and telemetry are separate deployment choices.

## AOI — grid vs quadtree, after physics

An older `StateSynchronizerManagerServer` includes an opt-in grid (`AOIMode.GRID`, default `NONE` there), but **that does not establish production 3D AOI**. [Experimental PR #18](https://github.com/PatrykCieszynski/Mandate-of-Three/pull/18) contains a separate interest-grid proposal; it is evidence, not a branch to merge wholesale. [Quantum Core X QuadTree](https://github.com/MeikelLP/quantum-core-x/blob/main/src/Core/Core/Utils/QuadTree.cs) is an alternative worth testing.

Under W5, benchmark spatial query, index update, allocation and **end-to-end replication cost** with identical dense horn pulls, moving mobs, sparse population and actual connected clients. Check enter/leave/re-entry, stale/ghost entities, equipment, hits, death, reconnect, snapshot recipients and bytes per peer. Dynamic quadtree updates can cost more than a flat grid for dense moving actors.

**Gate:** Same authoritative gameplay, meaningful repeatable performance gain, and no network/visibility regressions. W5/W6 define the actual acceptance work.

## Packet generators — later

The repo has typed binary encoding in `source/common/network/wire_codec.gd` (`StreamPeerBuffer`, `PackedByteArray`, field IDs). **Verify use in the current 3D runtime first**; a byte-oriented binary codec is not automatically bit-packed.

If packet schemas become hard to maintain, explore a single versioned definition that generates readable GDScript encoder/decoder code and golden-byte, round-trip, malformed-size, endianness and compatibility tests. Bound count/string/payload sizes. Benchmark traffic, encoding CPU and schema drift before introducing generator tooling; consider bitpacking/quantization independently.

**Non-goals:** Rewriting Godot RPC/transport or packing every bit without measured benefit.

## Follow-up rule

Keep physics in W0–W7, multi-process authority in the accepted ADR, and Economy guarantees in C1–C5. Each new topic needs its own narrowly scoped design or benchmark PR. Nothing in this backlog changes current runtime behavior.
