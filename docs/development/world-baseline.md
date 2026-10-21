# W0 World baseline — measurement contract

Opt-in baseline on the post-PostgreSQL, post-PR #88 code. No production source,
resource budgets, gameplay, worker counts or network protocol are changed.
The fixture reuses the existing workload support and current PlayerActor3D,
GameWorld3D movement loop, CombatEndpoint3D movement eligibility and MobSystem.
It does not transplant experimental movement or AOI implementations.

## Frozen cohorts

1. **Synthetic movement:** 0/0, 100/200 and 250/500 players/mobs; three repeats
   per case, requested 3-second warmup + 12-second Godot timer, 60 physics Hz/60 FPS.
   Dense uses the existing 32 m arena and obstacles; wide uses a flat 512 m
   floor. One singleton pack per dog, stationary pack anchors, no automatic
   acquisition; assigned targets chase using current AI/motion. Player intentions
   refresh at production cadence using simulation-time deterministic directions.
   Seed 1729; spawn radius zero. Attack cooldowns are held beyond the run, so
   this cohort has no damage/death/economic work. It is not gameplay parity.
   The reused support initializes four arena packs; their actors are removed,
   leaving four empty pack owners alongside the requested singleton packs.
   Its production CombatEndpoint also bakes arena navigation during startup;
   this contributes to whole-process peak RSS, especially for the 512 m floor.
2. **Ready binding/cache probe:** 0/24/64/65 requested Inventory + Wallet accounts,
   with 0/12/180 one-cell material items per Inventory. Actual public attach and
   session fingerprint checks run against fixture session maps, then the probe
   explicitly seeds ready projections. Executor poll returns no completions and
   performs no SQL. Measure 200 idle polls and 10 cache copies per admitted peer;
   detach clean accounts and verify release. This is not a native loading,
   recovery, login-burst or PostgreSQL throughput benchmark.
3. **Economy/combat integration:** retain the existing independent Representative
   Economy and MMO Integration runners and their durable invariant audits. Their
   existing evidence is not a substitute for fresh true-client W6 capacity data.
   Never run them concurrently with the CPU baseline and compare timings.

```powershell
python tests/run-world-capacity.py
python tests/run-world-capacity.py --cohort bindings
# Short diagnostic only; not the baseline acceptance window:
python tests/run-world-capacity.py --scenarios 0:0,2:4 --layout dense --repeats 1 --warmup 1 --seconds 3
```

Windows uses the actual `Godot_v4.7.2-stable_win64.exe`, **not** its small console
launcher: measuring the launcher's PID would report the wrapper's CPU/RSS.
No visible game window is opened (`--headless`, CREATE_NO_WINDOW). The runner
owns only its child; timeout kills that child, never a live Master/World/PG.
No sockets, databases or connection strings are needed. APPDATA and equivalent
directories are isolated under ignored `.godot/verification/world-capacity/`.

## Artifact schema v1 and interpretation

Every run stores raw stdout/stderr and `results.json`, with Git SHA/status,
tracked source fingerprint, executable SHA/version, OS/CPU, flags and repeats.
Measurements must use committed test code. Evidence-only documentation commits
after measurement do not change the measured control; record the measurement SHA.

- `physics_work`: p50/p95/p99/max span between early/late physics callbacks;
  includes fixture callbacks and movement/AI work, **not the entire native physics
  server step or all OS scheduling**. Use tick intervals and observed Hz alongside it.
- `tick_interval`: p50/p95/p99/max time between tick beginnings. Catch-up physics
  ticks may be bunched; average Hz alone can hide expensive frames.
- Godot timers can stretch relative to wall time under overload. Result `seconds`
  is the measured monotonic observation duration and is used for observed Hz;
  do not divide by the requested 12 seconds. Same engine-time trajectory and
  requested timer are held fixed; this is not a fixed-wall-duration arrival test.
- `over_budget_ticks`: callback spans above 16.667 ms, an observation, not a CI gate.
- Player snapshot construction mirrors the current production roster and runs at
  its cadence. One Variant serialization is a proxy; real per-viewer RPC encoding,
  sockets, compression and receivers are absent. Mob snapshot serialized size is
  sampled separately at the end. `actual_network_bytes=0` is deliberate.
- Static allocator memory differs from RSS. Windows CPU seconds and peak RSS are
  sampled every 100 ms from the actual child process over **its whole lifetime**,
  including startup/warmup/teardown; they are not observation-window-only metrics.
  Other platforms report native usage unavailable and remain NOT VERIFIED.
- Binding static memory includes the fixture PlayerResources/session maps and
  ready Inventory/Wallet dictionaries, not only bindings. Serialized snapshot
  bytes are not retained RAM. Empty snapshots still have framing cost.
- Inventory and Wallet are polled each process frame. Peer lookup scans account
  dictionaries; copying every peer in turn includes this scan and deep-copy cost.
  This diagnostic cannot establish the cost of more than 64 attached accounts.

No TPS/p95/p99 success threshold or advertised player capacity. Fail only for
broken setup, missing observations, count mismatch, script failure or lifecycle
assertion. Keep large runs out of default CI. W1 adds detailed nested hotspot
instrumentation and quantifies its overhead; W0 does not claim those timings.

## Preserved behavior and rollback

Production movement/physics, corpse lock, stun, knockback, attack advance,
collision policy, RPC authorization and Economy receipts remain unchanged.
Two-client movement/PvE, local instance routing and First Region fixtures remain
independent behavior gates. Flat synthetic runs do not validate Terrain3D slopes,
combat traces, reconnects or native input. Stop any later candidate if parity fails.
Rollback here is removal of the optional runner/fixtures and docs; no migration,
new service, live process change or feature flag is needed.
