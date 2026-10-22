# W1 — native World hotspot attribution

2026-10-21, based on accepted `main` **fd7ff57e** (PR #115 squash merge).
Measured test code **5d86ed311e1d09c7630e92ee9cc936d250143fae**, Godot
**4.7.2.stable.official.ed1daf0bf**, Windows 10 build 19045, AMD64 Family 25
Model 33 / 12 logical CPUs. Engine hash, source fingerprint, host metadata,
debug/editor flags and individual repeats are in ignored raw artifacts.
Only explanatory docs were dirty during measurement; test/production code was
committed and held fixed. Later evidence/docs commits do not change the control.

## Contract / changed boundary

Test-only nested timers around current native player motion, overlap query,
collision exceptions, advance/knockback and mob AI/motion; player roster and one
serialization proxy; physics/process callback intervals. Separate ready-cache
poll/lookup/copy probe. No production source, scene/content, configuration default,
worker, schema, RPC, economic mutation or authoritative motion changes.

See [method and rollback contract](../../development/world-profiling.md).
Generated subclasses extract current methods rather than maintaining an older
movement implementation. Exact insertion anchors fail closed before launch;
expected bucket coverage and actor/sample counts are checked after each run.
The original classes remain the unprofiled control. Removing optional test code
is the rollback; no live process or deployment change is required.

## Paired control vs profiling

`python tests/run-world-capacity.py --profile compare`: **36/36 PASS**.
Six cohorts (dense/wide x 0/0, 100/200, 250/500), three interleaved pairs each;
pair order reverses on repeat 2. Same executable/host/seed, requested 3-second
warmup + 12-second engine-time window, fixed 60 Hz physics / 60 max FPS.

All numbers below are medians of three runs. Units are milliseconds except Hz;
overhead is the ratio of the two physics-p95 medians, including scheduling noise.
The frame metric is the interval between `_process()` callbacks, not work duration.

| Layout / synthetic players+mobs | Physics p95 control | Physics p95 profile | Instrumentation overhead | Tick p99 control | Process interval p95 control | Observed physics Hz control |
|---|---:|---:|---:|---:|---:|---:|
| Dense 0/0 | 0.069 | 0.088 | +27.5% (0.019 ms) | 16.719 | 16.709 | 60.00 |
| Dense 100/200 | 19.101 | 20.022 | +4.8% | 21.660 | 148.075 | 58.48 |
| Dense 250/500 | 44.006 | 52.627 | +19.6% | 53.698 | 354.201 | 24.10 |
| Wide 0/0 | 0.069 | 0.077 | +11.6% (0.008 ms) | 16.712 | 16.707 | 60.00 |
| Wide 100/200 | 16.468 | 18.284 | +11.0% | 20.276 | 18.475 | 60.01 |
| Wide 250/500 | 44.464 | 47.508 | +6.8% | 58.278 | 366.137 | 25.67 |

Control physics p95 ranges across repeats: dense 100/200 **18.602–19.406**,
dense 250/500 **43.995–46.380**, wide 100/200 **15.128–18.006**, wide 250/500
**42.066–44.751**. Profile ranges respectively **18.998–20.941**,
**52.208–52.638**, **15.729–20.076**, **47.272–48.764**. Do not interpret a
small difference as an optimization or assume one constant overhead correction.

Observed Hz uses monotonic elapsed time; overloaded engine timers stretch.
Near-60 average physics Hz at dense 100/200 hides large process-frame gaps.
This demonstrates scheduling delay in the fixture, not measured RPC latency.

## Nested hotspots

Median of each profiled run's **mean aggregate milliseconds per sampled tick**.
These are not p95 values and not per-actor latency. Parent/child totals overlap.
Snapshot rows use only the snapshot-producing ticks (about 240 per normal run).

| Bucket | Dense 100/200 | Dense 250/500 | Wide 100/200 | Wide 250/500 |
|---|---:|---:|---:|---:|
| Player simulate, inclusive | 10.013 | 22.500 | 4.787 | 12.313 |
| Native player slide | 8.198 | 15.998 | 3.409 | 8.763 |
| Native player overlap query | 0.388 | 1.694 | 0.208 | 0.615 |
| Player exception add/list-read | 0.152 | 0.673 | 0.086 | 0.237 |
| Player exception removal | 0.059 | 0.226 | 0.038 | 0.098 |
| Mob tick, inclusive | 7.455 | 21.319 | 10.301 | 26.826 |
| Mob AI, includes motion | 7.052 | 20.009 | 9.826 | 25.479 |
| Mob motion, includes slide | 4.813 | 13.091 | 8.323 | 21.498 |
| Native mob slide | 4.188 | 11.246 | 7.501 | 19.406 |
| Player roster construction | 0.090 | 0.281 | 0.098 | 0.287 |
| One player roster encoding proxy | 0.018 | 0.037 | 0.019 | 0.038 |

Native motion is consistently a large cost, but its distribution changes with
layout. The wide scene reduces player cost and increases mob motion cost; at
250/500 overall control cost stays similar. Floor size, obstacles and placement
differ between cohorts, so this is **not an isolated proof of a density cause**.
Attribution does not establish why native mob motion costs more in that layout.

The measured native overlap query is only part of `_overlapping_mob_bodies()`;
query allocation and result filtering are in the enclosing player total. Do not
call the rest free. Likewise AI includes line-of-sight and other decisions plus
motion. Never add its inclusive cost to motion or subtract unrelated p95s.
Small timers and enclosing residuals include clock/collection/dispatch overhead.

## Ready binding/cache probe and active displacement

`python tests/run-world-capacity.py --cohort bindings`: **3/3 runs PASS**, 12
cases per run. Public attach/lookup/poll/copy/detach methods, seeded ready caches,
no SQL or worker completions. Account 65 is refused by both original 64-slot
owners, clean detach releases both maps. No limit was raised for this experiment.

For full 180-item Inventories, medians of the three batch means, in microseconds:

| Requested / admitted | Inventory poll, all accounts | Wallet poll, all accounts | One Inventory context lookup | One snapshot copy including lookup |
|---|---:|---:|---:|---:|
| 24 / 24 | 63.800 | 19.610 | 4.617 | 551.208 |
| 64 / 64 | 140.160 | 46.930 | 6.345 | 559.677 |
| 65 / 64 | 149.120 | 52.165 | 6.728 | 545.231 |

Context lookup is a different operation from snapshot copy; subtraction is not
an exact copy-only cost. These are per-invocation probes, not actual per-frame
copy traffic or native login/recovery latency. Existing production snapshot
publication frequency must be inspected before extrapolating.

`python tests/run-world-capacity.py --profile compare --displacement --scenarios
2:4 --layout dense --repeats 3 --warmup 1 --seconds 5`: **6/6 PASS**.
Uses current `start_attack_advance()` / `apply_knockback()` every alternating two
simulation seconds; existing traces, attacks and damage are not simulated.
Control/profile median physics p95 **0.654 / 0.711 ms** (+8.7%). This exercises
active movement branches, not gameplay parity, knockdown authority or combat feel.

## Artifacts / verification limits

All artifacts are ignored under `.godot/verification/world-capacity/`:

- Matrix: `20261021-173654/results.json`, raw `.out.log`/`.err.log`, generated
  `profile/*.gd`. SHA-256 of generated source uses LF-normalized UTF-8 text.
- Ready bindings: `20261021-175535/results.json`.
- Displacement: `20261021-175551/results.json`.
- Runner logs: `.godot/verification/world-w1-profile-matrix.log`,
  `world-w1-bindings.log`, `world-w1-displacement.log`.

Default smoke: **PASS**, including architecture guards, the existing gameplay/
economy cases and all **88 Web UI contracts** (`world-w1-smoke.log`).
`git diff --check` and Python compilation pass.

Headless editor import is **NOT a clean pass**: it exits 0 but reports a Nil/int
assignment in unchanged `addons/terrain_3d/src/double_slider.gd:25` and missing
`navigation_map` in unchanged `terrain3d_spike/terrain_spike.gd:19` while restoring
the editor scene. Both persist on an isolated editor profile; no W1 script parse
error was reported. Logs: `world-w1-import.log`, `world-w1-import-isolated.log`.
Do not infer editor/Terrain3D correctness from the successful simulation runs.
No plugin/terrain fix is included in this profiling PR. The import-created,
previously absent untracked UID sidecars were removed, preserving tracked source
and editor/import caches; the owned list is in `world-w1-import-generated-uids.txt`.

No live Gateway/Master/World/PG restart, production data access or visible game
window. Synthetic actors are **not connected clients**; actual network bytes=0.
Physics-work callbacks exclude parts of native physics/OS scheduling. Whole-process
CPU/RSS include startup/navigation bake/warmup/teardown, not just observation.
Existing root-certificate and 4-ObjectDB/3-resource teardown diagnostics remain
in both control/profile; no new script/assertion errors. No leak-free claim.

Native loading/recovery/login bursts and queue saturation remain in existing PG
behavior suites; they were not newly profiled here. Linux, physical CEF input,
Terrain3D slopes/steps, actual combat damage, connected clients, AOI fan-out and
integrated MMO load are **NOT VERIFIED** by these synthetic measurements.
Mob snapshots are sized once after observation, not separately timed in the
periodic replication path. Player snapshot proxy timings do not cover that path.

## Next gate

W1 identifies native player motion as a worthwhile W2 candidate, particularly
in dense contact, but it is not the sole bottleneck. Preserve the original
controller as default/fallback and prove geometry/combat/authority parity before
promotion. Do not remove overlap safety, add an all-actor GDScript broadphase,
change tick rates or raise session budgets based on these numbers. W3 actual
terrain and conditional W4 mob work remain necessary gates; W5/W6 must measure
real fan-out and connected-client responsiveness. No optimization is approved
or automatically merged by this evidence.
