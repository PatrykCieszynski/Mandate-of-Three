# Headless World capacity baseline (experimental, opt-in)

This benchmark is **not** evidence of MMO client capacity. It compares the
cost of running many actors inside the **current production Godot World code**,
without rewriting gameplay or affecting the main branch. The synthetic peer IDs
are never connected to a transport.

## Run

Use the project's pinned Godot 4.7.2 executable with a fully imported checkout,
installed project addons and their native libraries. No Master or production
database is started. Each run starts a local, isolated World on port **18109**
and leaves its JSON/CSV/log files under `.godot/verification/world-capacity/`.

```powershell
python tests/run-world-capacity.py --godot .godot/Godot_v4.7.2-stable_win64_console.exe
```

Linux:

```sh
python3 tests/run-world-capacity.py --godot /path/to/godot
```

Defaults: `0:0,100:200,250:500,500:1000` (synthetic players:mobs);
3-second warmup plus 12-second measurement, one fresh process per scenario.
The final population is deliberately demanding and can be slow. Choose an
initial smaller sweep, then repeat the full one:

```sh
python3 tests/run-world-capacity.py --godot /path/to/godot --scenarios 0:0,25:50,50:100 --repeats 3
python3 tests/run-world-capacity.py --godot /path/to/godot --scenarios 100:200,250:500,500:1000 --repeats 3 --timeout 300
```

To measure a pessimistic **snapshot encoding CPU proxy**, execute an otherwise
identical sweep with `--encode-per-peer`. Do not mix these runs when comparing
physics timings. The proxy calls `var_to_bytes()` per synthetic peer; it is
**not** the Godot RPC wire codec, packetization or network bandwidth.

## What actually runs

- The real headless `GameWorld3D` and actual `PlayerActor3D.simulate()`
  in the regular World physics callback, with 20 Hz simulated movement input.
- The real `MobSystem.tick()`, `MobActor3D.simulate_mob()` and physics
  bodies. Mobs follow a deterministic target assignment; combat attacks are
  suppressed because the pretend peers have no network endpoint.
- The real full-roster snapshot *construction pattern* (20 Hz), with binary
  serialization measured separately. Only the fixture overrides the broadcast
  method to prevent RPCs to nonexistent peer IDs.
- A no-database headless World, matching the project's 60-Hz physics and
  60-FPS cap. Actor creation, navigation baking and warmup are excluded from
  the timed interval.
- A probe before and after physics work measuring wall-clock callback time,
  tick intervals, samples exceeding 16.67 ms, observed ticks/s, static memory,
  snapshot build/encode time and a deliberately labeled outbound-size estimate.

The load fixture manually calls the production mob tick because the actual
CombatEndpoint only ticks mobs after the persistent item domain is ready.
The synthetic benchmark deliberately does **not** create that database. As a
result, the measurement covers the core algorithms and physics but not the
full combat/DB path. This difference must be accounted for.

## Explicitly NOT tested

- **Not 100/250/500 authenticated players or WebSocket/ENet connections.**
  No client-side frame time, actual RPC serialization, network throughput,
  socket buffers, packet loss, congestion or disconnect behavior.
- No Economy, Inventory, Marketplace, wallet or checkpoint load; no persistent
  player identities. No real combat damage, rewards, skill spam, mob deaths or
  respawn-driven workload.
- No full terrain, map streaming, dense regional geometry or production mob mix.
  The default test arena is a small 32x32 fixture.
- No real-world performance claim: results are host-, build-, OS- and
  binary-dependent. Do not set a player-capacity threshold from this fixture.

## Reading results

Compare the baseline `0:0` and populations on the **same machine**, engine
binary, project commit and configuration. Focus on `physics_work.p95_ms`,
`physics_work.p99_ms`, `tick_interval.p99_ms` and
`observed_ticks_per_second` rather than only average execution time.
Physics callback work over 16.67 ms or fewer than ~60 observed ticks/sec
indicates that the tested machine is struggling with the imposed load, not that
this number of actual MMO connections is impossible.

Also compare the baseline to `--encode-per-peer` to see whether quadratic
full-roster serialization is likely to be a concern. The estimated MiB/s is
`snapshot bytes x peer count`, not observed socket bytes or authoritative
network bandwidth.

## Next required experiment before choosing the server stack

Run a **separate** true multi-client benchmark with authenticated lightweight
bot connections in external processes and instrumentation of:
- Actual clients connected, received updates and disconnected/reconnected;
- Server CPU/memory, tick p95/p99, dropped ticks and actual outbound bytes;
- Network and gameplay actions (movement, combat, occasional inventory writes);
- 100, 250 and 500 concurrent connected clients at controlled density.

Compare it with this simulation-only baseline. If real-client performance
collapses while core simulation holds up, profile RPC fan-out, serialization and
transport **before** concluding that the Godot simulation runtime must be
replaced. If the simulation itself collapses, profile the specific physics/AI
hotspot and test a narrow native rewrite.

This is an **opt-in experiment**, not CI regression gate or production benchmark.
