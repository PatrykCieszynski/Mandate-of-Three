# W4a â€” lightweight mob movement and Terrain3D sampling

2026-10-21. Experimental candidate; native remains default. PR #116 was
squash-merged before branching from main `8a412791`.

## Contract and selection

Only World startup flag `--dev-light-mob-movement` enables ordinary XZ movement
without `move_and_slide()`. Native CharacterBody3D, BODY layer, defending capsule,
AI, combat authority, replication and player motion remain. Knockback always uses
native collision/damping. Missing or ambiguous support falls back to native motion
with the original intention, rather than freezing XZ or inventing a Y.

One map-owned grounding provider is shared by its spawned mobs. Empty
`GameWorld3D.mob_grounding_terrain` uses a short floor ray. An explicit map-owned
Terrain3D path uses actual `Terrain3DData.get_height(global_position)` every tick.
No height cache, scheduler, interpolation or extra mob scan was introduced.
Non-finite/missing/hole data, unsupported global transforms and height changes
outside +0.4/-0.75 m refuse direct grounding. Low bridges/multiple floors require
ray mode; the heightmap cannot identify their surface. This is a point-foot
approximation, not general capsule/slope/platform parity.

See [setup and commands](../../development/lightweight-mob-movement.md).

## Host and methodology

Windows 10 19045, Ryzen 5 5600X, 12 logical CPUs; Godot
4.7.2.stable.official.ed1daf0bf, actual headless debug/editor executable rather
than console-wrapper process. Engine SHA256:
`ab1824f85bfd8e0e4128182c000c4003a3e042245b2967848d089b2a04b22424`.
Terrain3D 1.0.2. Developer desktop, not dedicated hardware; local processes were
not stopped, and no other verification workloads ran alongside the load matrix.

Comparisons use the same commit, deterministic seed 1729, 60 Hz target, profiling
off, 3 s engine-time warmup and 12 s engine-time observation, three repeats with
reversed order on the second repeat. Engine time under overload takes longer
than wall-clock target; reports retain actual elapsed time and observed Hz.
Physics work, tick interval and process-frame interval are separate measurements;
process-frame interval is not a rendered client FPS measurement.

These are synthetic server actors with snapshot construction/encoding proxy.
There are no sockets, real clients, DB/economy, real combat damage or RPC fan-out.
Player physics remains native. Input refresh is simulation-time based and expiry
is wall-clock based; severely overloaded runs can alter actor trajectories. Same
seed is not proof of identical collision contacts between different controllers.

## Ray reference on box support

Measurement commit `639890b5dc26044acf65aa5370c2156cd243e459`. 24 runs, dense
and wide, 100/200 and 250/500 players/mobs. The report records new untracked
height-provider/fixture files and documentation created during the cohort; none
was wired into or changed the loaded ray/native code during that measurement.
Do not treat this as a perfectly clean-tree run or use it as the height cohort.

| Layout | Players / mobs | Native physics p95 | Light ray p95 | Change |
| --- | ---: | ---: | ---: | ---: |
| Dense | 100 / 200 | 20.932 ms | 20.427 ms | -2.41% |
| Dense | 250 / 500 | 51.624 ms | 41.668 ms | -19.29% |
| Wide | 100 / 200 | 17.121 ms | 10.634 ms | -37.89% |
| Wide | 250 / 500 | 43.147 ms | 25.543 ms | -40.80% |

Values are medians of each run's p95, not a pooled p95. Raw report:
`.godot/verification/world-capacity/20261021-183506/results.json`.

## Full Terrain3D collider diagnostic

Disposable native flat Terrain3D, four regions, replaces the box support. On the
uncommitted height follow-up, a short 2/4 diagnostic (one run, 1 s warmup/3 s
observation) measured physics p95 native 5.730 ms, ray 1.684 ms, height 1.660 ms.
A separate native-only 100/200 probe (one run, 1 s/1 s) measured p50 116.627 ms,
p95 140.944 ms and 8.223 observed Hz. This is an overload warning, not a repeated
capacity estimate or a matched large-cohort height-vs-native improvement claim.

Raw reports: `20261021-185553/results.json`, `20261021-185721/results.json`
under `.godot/verification/world-capacity/`. Their recorded HEAD is the ray
commit with uncommitted height setup; do not attribute them to the final commit.

The full collider cost would dominate a large comparison and can affect input
expiry under overload. Therefore the larger three-way cohort below retains one
common box collider and real Terrain3D data, explicitly disabling only terrain
collision. It isolates movement/API cost. It does not prove performance on a
full Terrain3D collider with hundreds of native player bodies.

## Three-way comparison with common box support and real Terrain3D data

Measurement commit `fb14466488a3e4fdf6465af0e86288307d15b649`, clean working tree
in the report. Source/test SHA256:
`d91ed0b072ba55387d7b1b9fcffb00e9294de2f2f71d29ce1efb88257ff649c1`.
18 accepted runs. Raw report:
`.godot/verification/world-capacity/20261021-190608/results.json`.

```powershell
python tests/run-world-capacity.py --terrain --terrain-collision box --mob-movement compare --mob-grounding compare --layout dense --scenarios 100:200,250:500
```

Native/ray/height all keep the same box floor. The native Terrain3D data is
present in every process; its collision is explicitly disabled. Every measured
light tick used direct support (zero native fallback), verified from counters.
This tests real height API use, not a fake constant-Y provider.

| Players / mobs | Movement | Physics p95 median (range) | Physics p99 median | Tick p95 median | Observed Hz median | vs native p95 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 100 / 200 | Native | 22.542 ms (20.028–24.156) | 24.705 ms | 23.282 ms | 56.18 | +0.00% |
| 100 / 200 | Light + ray | 17.656 ms (17.148–20.411) | 22.437 ms | 18.314 ms | 60.00 | -21.68% |
| 100 / 200 | Light + height | 15.834 ms (15.545–18.008) | 19.027 ms | 16.718 ms | 59.88 | -29.76% |
| 250 / 500 | Native | 49.140 ms (42.513–52.649) | 54.455 ms | 51.113 ms | 24.46 | +0.00% |
| 250 / 500 | Light + ray | 38.539 ms (35.458–43.336) | 46.542 ms | 40.591 ms | 30.25 | -21.57% |
| 250 / 500 | Light + height | 41.631 ms (33.817–47.375) | 47.299 ms | 44.396 ms | 28.98 | -15.28% |

Whole-process peak RSS medians are about 232 MiB (100/200) and 264–267 MiB
(250/500), with no material candidate memory increase. Whole-process CPU seconds
include startup, warmup and longer wall-time observation under overload; they
are not instantaneous CPU percentages. Native/ray/height CPU seconds medians:
18.766/16.219/16.000 at 100/200 and 42.234/33.969/35.484 at 250/500.

Height is faster than ray at 100/200, but not at 250/500 in these repeats. The
250/500 height p95 ranges from 33.817 to 47.375 ms; contact trajectories, scheduling
and desktop noise remain material. Do not claim a universal height-over-ray win.
There is no evidence here justifying a cache or lower sampling cadence. Direct
height sampling is a viable simple candidate, with explicit surface selection.
Both candidates remain far over the full 60 Hz tick budget at 250/500. Even
100/200 height has little headroom at its 15.834 ms physics p95, before real
transport/combat/economy. W4a is an improvement, not completed World optimization.

## Verification

- `git diff --check`; Python compilation of benchmark/profile generator.
- Default smoke, including floor/hitbox/knockback/death/unsupported-edge contract
  and 88 Web UI contracts: PASS.
- Saved native Terrain3D flat/uphill/downhill routes for native, ray and height:
  PASS. Height used 60 direct ticks/0 fallback ticks on each route; the ray
  downhill route used 52 direct/8 native ticks. This is why missing point support
  must retain native motion rather than block the chase.
- Translated actor parent/global height coordinates, missing regions, holes,
  excessive rise/drop, nonidentity terrain guard, and ray-grounded low bridge:
  PASS. Only disposable data is mutated; saved authoring resources are read only.
- Native and light PvE, server + two clients, persistent ground pickup/relog:
  PASS. Light combat feel and real combat-trace network: PASS. Shared-provider
  follow-up reran light PvE/trace after wiring; native behavior is also in smoke.
- Light pack lifecycle regression: PASS. Small height/profile and binding-cohort
  compatibility diagnostics: PASS (12 binding cases).

Current logs: `.godot/verification/world-w4a-*-final.log`,
`world-w4a-height-profile.log`, `world-w4a-bindings-final.log`. Earlier native/
light PvE, feel/trace logs preserved in `world-w4a-network/`.

No visible game windows, live DB mutations, live-server restarts or edits to the
map author's clone. Local certificate/log-permission warnings and existing
4 ObjectDB/3-resource teardown warnings remain; the saved terrain also emits an
interpolation deprecation warning. No script/assertion errors occurred in the
accepted runs. No leak-free native shutdown or visual camera/input parity claim.

The candidate remains opt-in. Full stair/cliff/platform/penetration parity and
physical two-client playtesting on the authored map remain NOT VERIFIED. W2/W3,
AOI, real-client capacity and production rollout are not completed by this PR.
