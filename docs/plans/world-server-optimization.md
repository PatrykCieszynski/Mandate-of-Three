# World Server optimization — staged execution plan

**Status:** W0 audit/baseline and session/control/cache capacity integrated (PRs #114–115), 2026-10-21. W1 test-only profiling is the current review package; see [profiling contract](../development/world-profiling.md). Later implementation packages remain proposed and require review. This document is **not authorization to implement** a physics rewrite or merge experimental PR #18 into `main`.

Current W0 deliverables: [limit ownership audit](world-w0-limit-audit.md) and
[measurement contract/runner](../development/world-baseline.md). Configuration
implementation for workers/operation budgets remains separate; no limits are raised in W1.

**Target:** Keep Godot 4.7.2 as both client and authoritative World Server. Reduce unnecessary physics and per-viewer replication work while keeping the Metin-like gameplay contract, existing Economy ownership, RPC/session security and instance architecture intact.

**Reference:** [Pre-alpha hardening](../history/postgresql-migration.md), [World MapInstance/channel ADR](../architecture/world-instance-architecture.md), [Economy C1–C5](../architecture/economy/README.md), and the historical [experimental World PR #18](https://github.com/PatrykCieszynski/Mandate-of-Three/pull/18). The experiment branch is evidence/source code, **not** a branch to merge wholesale over the newer Economy/SoC work.

## 0. Execution rules (for Codex)

1. **Gate:** First finish the Economy roadmap, then the agreed *small* SoC refactor. Re-evaluate `main` after both: file paths, ownership, current tests and recent performance numbers may have changed. Do not carry old versions of Economy/Marketplace/Combat from experimental branches.
2. **Integration:** Rebase the *plan* against latest `main` at execution time. For each W-package, make a narrow `codex/world-opt-wN-*` branch based on the current accepted integration head. One coherent behavior/measurement contract and independently reviewable PR per package. No multi-package giant commit; no force-push of reviewed work. Merge to `main` only after user review.
3. **Baseline before changes:** Same Godot executable, hardware, build mode, arena/density, simulation seed, warmup and number of repeats; compare against the **same-commit instrumented control**, never unrelated versions of the benchmark. Record git SHA and flags for both sides. A positive ablation result is **not** feature parity.
4. **Gameplay first:** Preserve server-authoritative accepted input, movement speed cap, packet/sequence/timeouts, corpse lock, stun, knockback, attack advance, scenery wall/blocking, mob-body blocking and release, line of sight, hit traces and combat timing. No client-trusted position or silent changes to anti-cheat. Mobs currently ignore scenery during ordinary chase and never collide with other mobs; do not add expensive navigation.
5. **Avoid reflexes:** Do **not** add a scripted all-mob/player spatial scan or custom physics broadphase without proving an isolated end-to-end gain: the earlier GDScript overlap index severely regressed dense loads. Do **not** replace `intersect_shape()`, physics casts, terrain or combat hit trace on intuition alone. No blanket 30Hz tick change or C++/GDExtension without a measured bottleneck.
6. **No unrelated architecture work:** Do not introduce Nakama, Go, PostgreSQL, ORM, job bus, new Economy writes/worker, extra World processes, a new MapInstance scheduler or a new client protocol in optimization PRs. The accepted ADR already covers eventual dynamic channels and separate economy ownership.
7. **Rollback:** Keep old behavior callable behind a **temporary server-side** controller selector/feature gate until parity and load gates pass. No global rollout and no removal of fallback before acceptance. Feature flags are for controlled comparison, not a permanent second physics engine.
8. **Evidence:** Each PR states invariant, changed files, failure/rollback cases, executed commands, before/after measurements (median of >=3 repeats), CI status, and *not-tested* cases. No performance numbers hardcoded as flaky CI assertions. No generated logs, runtime DBs, local addons or synthetic results committed as executable truth.

**Runtime capacity/configuration supplement:** [World runtime configuration and capacity budgets](world-runtime-configuration.md) adds a W0 audit of hardcoded limits, server-only validated settings, a commented example and W6 binding/real-client capacity gates. It does not change the W0–W7 sequence or authorize higher runtime defaults.

## 1. Evidence already collected (diagnostic, not capacity claims)

The experiment simulated **250 players + 500 mobs** in one World without 250 connected network clients, durable Economy, real combat damage, or complete RPC transport. Physics instrumentation and actor subclassing add overhead.

| Workload / controller | Physics work p95, median across three runs | Observed ticks/sec, median | Interpretation |
| --- | ---: | ---: | --- |
| Dense 32x32 m, native player motion | ~42.44 ms | ~28.9 | Over budget; contact density dominates |
| Wide 512 m floor, native player motion | ~21.65 ms | ~58.2 | Distribution cuts a large fraction of cost |
| Dense 32x32 m, test-only `--light-player` | ~21.70 ms | ~56.8 | Promising *non-equivalent* flat XZ motion |

Dense native 250/500 mean per physics tick: `PlayerActor3D.simulate` ~21.49 ms, including player/mob overlap ~2.93 ms; `MobSystem.tick` ~10.19 ms, including mob movement ~3.68 ms. Wide: player ~9.72 ms, overlap ~0.76 ms, mob ~5.19 ms, mob movement ~3.45 ms. These are **nested timing buckets**, not additive totals or matched p95 numbers.

The light prototype uses the benchmark-only `tests/fixtures/lightweight_player_motion.gd`, two XZ capsule casts and no normal `move_and_slide()` for players. It **does not** implement ground elevation, slopes, stairs, moving platforms or full penetration recovery. Its green smoke suite does not imply safe production movement.

**Physics 60Hz time budget:** 16.67 ms *for the entire server tick*; leave headroom for transport/serialization, combat, scripting, OS scheduling and persistence-adjacent work. A single synthetic p95 near 16.67 ms is not a production-ready capacity result.

## 2. Package sequence and gates

| Package | Deliverable (separate small PR) | Depends on | Pass / stop gate |
| --- | --- | --- | --- |
| **W0 — Reconcile & freeze contracts** | Inventory the latest post-SoC player/world/combat interfaces; pin scenarios, invariants and a baseline artifact schema; verify smoke/network runners. No gameplay changes. | Economy + SoC integrated | Baseline repeatable; true control and diagnostic modes labeled; open parity decisions documented |
| **W1 — Profile actual player cost** | Subtimers around player `move_and_slide()`, shape queries, exception mutations and advance/knockback, plus MobSystem AI vs motion, snapshot build and frame scheduling. Instrumentation **test-only**. | W0 | Hotspot ranking repeatable across dense + wide; timers are nested and measurement overhead reported |
| **W2 — Production candidate player controller** | Small movement policy/adapter using already-refactored SoC boundary, with native geometry casts where appropriate; opt-in **server-only**, old motion default. Reuse experiment, do not transplant old World files. | W1 | Flat arena movement/wall slide/speed/overlap escape/attack advance/knockback parity with authoritative legacy path; measurable improvement |
| **W3 — Terrain and combat parity** | Make candidate work on actual First Region/Terrain3D geometry; explicit height sampling/grounding strategy, slope/cliff/stair and boundary rules, collision resolution and combat hit-trace integrity. | W2 | Actual-map test matrix, mixed contacts, no tunneling/invalid heights, no speed exploit, network feel; if parity impossible cheaply, stop/revert candidate |
| **W4 — Selective mob optimization (conditional)** | Only if W1/W3 profiling shows a significant remaining mob bottleneck: inspect AI decisions, pack lifecycle, idle physics and grouping. Otherwise skip and document why. | W1, W3 | Independent improvement with identical mobs/AI parity; no new scripted collision index or changes to pack loot/respawn semantics |
| **W5 — AOI / network replication** | Review transplantable parts of experimental PR #18 on top of *current* main: viewer interest, reliable membership, weapon replay, player/mob snapshot cadence, event scopes; instrument bytes and fan-out. | W3 and SoC world boundaries | Real 2-client AOI enter/exit/re-enter, equip/hits/mob/reconnect; no stale/ghost actors, reliable queues controlled |
| **W6 — True connected-client load** | Opt-in multi-process lightweight bot harness (real sockets/auth/session/RPC and periodic gameplay); repeatable density and arrival patterns, independent server CPU/tick/bytes/RSS/GC telemetry. | W5 | Measure 2/10/25/50 then 100/250 (and 500 only if safe); no fictional connected-client count; classify simulation vs serialization vs IO bottlenecks |
| **W7 — Acceptance / rollout decision** | Compare current `main`, old controller fallback, new controller + AOI at equivalent gameplay load; publish evidence and rollback switch policy. Decide whether to ship changes one by one. | W0–W6 gates | Maintainer acceptance, no gameplay/security regression, sustainable tick and network headroom at agreed target workload; otherwise keep experiments shelved |

W0–W3 are the **critical path**; W4 is not a prerequisite if mobs remain cheap. W5/W6 distinguish near-60Hz synthetic physics from a real multiplayer server. W7 is a review decision, not an automatic merge.

## 3. Practical test matrix and files to inspect

These are **starting paths** from current `main` and PR #18; check after SoC before changing anything:

| Concern | Starting points |
| --- | --- |
| World movement/input/replication | `source/common/gameplay/world3d/game_world_3d.gd`, `source/common/gameplay/world3d/actors/player_actor_3d.gd`, `actor_3d.gd` |
| Mob simulation/pack lifecycle | `source/common/gameplay/mobs/mob_system.gd`, `source/common/gameplay/world3d/actors/mob_actor_3d.gd` |
| Combat/hit trace and knockback | `source/common/gameplay/world3d/combat/combat_endpoint_3d.gd` and linked attack/trace services; `tests/hit_reactions.gd` |
| Region/terrain | Actual map scene, Terrain3D collision/bake/export and `tests/first_region.gd` |
| AOI experiment | PR #18 `world_interest_grid_3d.gd`, `tests/aoi_network.gd`, `docs/development/world3d-aoi-experiment.md` |
| Performance fixtures | PR #18 `tests/run-world-capacity.py`, `tests/world_load_bench.gd`, `tests/fixtures/lightweight_player_motion.gd` |

**Contract fixtures required by W2/W3:**
- Normal speed, diagonal normalization, malicious direction and stale/reordered input; stationary/corpse/stun/movement locks.
- Wall, pillar, narrow corridor, corner glancing/sliding, parallel traversal and starting penetration; standstill and moving mobs blocking players, escaping existing overlaps, no mob–mob collision.
- Finisher advance, knockback into wall, interruption, hitstun/down/get-up, mob death freeing contact, drop pickup.
- Real terrain: hills, stairs, boundary, elevation transition/cliffs, first spawn and nearby obstacles; visible/client position must agree with server authority.
- 1 player + 20/50/100 mobs (horn/pulling), 2–10 players contesting a dense spot, sparse map population, 250/500 synthetic *stress only*; confirm actual damage and hit traces, not merely physics motion.
- Connection/disconnection, AOI boundary movement, own actor always visible, position snapshot loss/reordering and equip state after re-entry.

**Established starting commands** (verify runner options against the branch at execution time):

```powershell
$godot = ".\.godot\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . --import
& $godot --headless --path . --import
pwsh -NoProfile -File .\tests\run-smoke.ps1
pwsh -NoProfile -File .\tests\run-pve.ps1
pwsh -NoProfile -File .\tests\run-combat.ps1
pwsh -NoProfile -File .\tests\run-combat.ps1 -Scene warrior_action_polish -MarkerPrefix ACTION
pwsh -NoProfile -File .\tests\run-first-region.ps1
# Available in experimental PR #18, not currently in main:
pwsh -NoProfile -File .\tests\run-combat.ps1 -Scene aoi_network -MarkerPrefix AOI
python tests/run-world-capacity.py --godot .godot/Godot_v4.7.2-stable_win64_console.exe --scenarios 100:200,250:500 --repeats 3 --timeout 300
python tests/run-world-capacity.py --godot .godot/Godot_v4.7.2-stable_win64_console.exe --scenarios 250:500 --wide --repeats 3 --timeout 300
python tests/run-world-capacity.py --godot .godot/Godot_v4.7.2-stable_win64_console.exe --scenarios 250:500 --light-player --repeats 3 --timeout 300
```

Network suites sharing a local port must run **sequentially**. Do not run expensive load tests in standard CI; add small deterministic behavior contracts to CI and run stress manually/opt-in. Economy PRs must retain their existing race, transaction, WAL recovery and market-under-combat gates; physics optimization may not remove those tests.

## 4. Measurement protocol and success criteria

**Separate test cohorts:**
1. Baseline actor-only synthetic World: 0/0, 100/200, 250/500 dense and wide; same commit, clientless, same instrumentation.
2. Gameplay-parity: real attack, aggro, damage/death, knockback and dense pulling against actual map and realistic spot densities. Capture CPU costs, not just pass/fail markers.
3. True socket/RPC clients: 2–250 connected bots, with actual session admission, AOI and controlled movement/combat; gradually increase only while server remains responsive.

**Record for every test:** commit SHA, branch, Godot build/debug vs release, Windows/Linux and CPU, active clients versus synthetic actors, arena dimensions, mob/pack count, scenario seed, profiling flags, warmup/measurement length, p50/p95/p99 callback work, p95/p99 tick interval, overruns, actual observed Hz, process CPU/RSS, GC pauses if measurable, snapshot recipients, actual bytes sent/received and per-peer traffic where instrumentable. Preserve raw unmodified logs under ignored `.godot/verification`; keep only a short human-readable evidence table in the PR.

**Improvement gate:** For a candidate optimization, require a repeated, material gain in the same workload **without** a meaningful tick p99 regression or gameplay/security changes. For W2 aim for a demonstrable ~20% or better player hotpath saving in dense gameplay-parity scenarios; this is a **decision threshold**, not a guaranteed benchmark. A 250/500 dense 32x32 m synthetic setup is an adversarial diagnostic, **not** a live population SLA. Set final live-client capacity targets only after W6 establishes realistic workload and required headroom. At 60Hz the total tick target is below 16.67ms, preferably with meaningful operating margin.

**Stop and reassess if:** candidate fixes a profiler number but breaks collision/recovery; requires a bespoke full physics engine; creates a GDScript O(players*mobs) scan; increases authoritative attack ambiguity; inflates reliable network queues; or cannot preserve user-visible gameplay. Revert and keep old controller; evaluate smaller native/GDExtension hotspot only with proof. A 30Hz simulation alternative is a separate behavior-changing experiment only after frame-budget evidence and combat feel testing.

## 5. Codex handoff contract

For each package, give Codex exactly this instruction, replacing `W<N>` and scope:

> Implement **W<N> only**, using this plan as the contract. First inspect latest accepted `main` and relevant SoC/Economy interfaces; explicitly list preserved behavior, affected files, measurement/control fixture, acceptance checks and rollback. Create a separate narrow branch; do not edit unrelated Economy, networking or map systems. Run targeted smoke, network and map tests appropriate to the package and capture same-commit A/B results. If the contract depends on an unimplemented previous gate, or gameplay parity fails, **stop and report instead of improvising a major redesign**. Leave a short evidence summary, open issues, and next package readiness in the PR. Do not merge to `main` without user approval.

**Approval points:** accept this plan separately from executing it; approve each W-package PR separately; approve promotion of the performance controller to default only after W7 acceptance. Keep this plan updated when a package's assumptions or owner change—never silently treat a proposed optimization as implemented.
