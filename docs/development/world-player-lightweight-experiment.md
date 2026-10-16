# Experimental lightweight player movement (flat arena only)

Consolidated branch: `experiment/world-headless-capacity-baseline` (original development branch: `experiment/world-player-lightweight-motion`). **No production player movement or network changes from the lightweight controller; it is test-only.**

## Question

At 250 synthetic players and 500 mobs we measured player simulation around
21.5 ms/tick in dense placement and 9.7 ms/tick in sparse placement, of which
mob overlap queries were ~2.9 and ~0.76 ms/tick. Before changing the live game,
test whether avoiding the expensive `CharacterBody3D.move_and_slide()`,
penetration exception lists and vertical floor solves is worth pursuing.

## Implementation

- `tests/fixtures/lightweight_player_motion.gd` is a **test-only controller**.
- The existing `BenchPlayerActor` uses it only with `--light-player`; otherwise
  it continues to call the original `PlayerActor3D.simulate()`.
- Uses planar XZ velocity and two native `cast_motion()` capsule sweeps
  (first X, then Z) against scenery and mob bodies; checks already-overlapping
  mobs to allow retreat and avoid further penetration. The player is still a
  `CharacterBody3D` resource because combat and replication depend on it,
  but its native character motion solver is not called in this mode.
- Keeps server input limits, facing, hit lock, attack advance cancellation,
  knockback damping and the existing collision capsule.
- **Not feature-equivalent**: no gravity, Y snapping, arbitrary-slope sliding,
  step climbing, moving platform support, or full 3D geometry validation.
  Two axis sweeps have directional bias and differ from physics collision
  recovery. Cannot be used in production until these are addressed and
  gameplay regressions are checked.

## Verify

First import Godot (twice if its GDScript class cache is stale), then:

```powershell
pwsh -File .\tests\run-smoke.ps1
# Baseline (same commit, same machine, no player motion ablation):
python tests/run-world-capacity.py --godot .godot/Godot_v4.7.2-stable_win64_console.exe --scenarios 100:200,250:500 --repeats 3
# Test-only lightweight player controller:
python tests/run-world-capacity.py --godot .godot/Godot_v4.7.2-stable_win64_console.exe --scenarios 100:200,250:500 --repeats 3 --light-player
# Compare on the sparse fixture too:
python tests/run-world-capacity.py --godot .godot/Godot_v4.7.2-stable_win64_console.exe --scenarios 250:500 --wide --repeats 3 --light-player
```

Mode output is separated in `results-simulation.json`,
`results-simulation_light_player.json`,
`results-simulation_light_player_wide.json`.
Both modes use the same 20 Hz input and 60 Hz physics schedule and synthetic
players, **not real WebSocket clients**.

Success for this spike means significant lower cost **and** correct flat-arena
blocking/contact/knockback. It does not justify merging into `main`. If it
fails to beat the baseline, discard the prototype rather than weakening
gameplay to chase performance.

## Consolidation and roadmap

This experiment is consolidated with the headless World benchmark, World3D AOI
prototype, and mob movement/respawn hotpaths in the single Draft PR #18. The
former performance source PR #22 contained a scripted player/mob collision
index that regressed dense-load performance and was intentionally removed.

Keep this branch experimental. The planned order is: Economy rework, small
Clean Code / separation-of-concerns refactor, then revisit world movement
optimization and production parity. Do not merge benchmark-only controller
into production movement without terrain, collision and real-client tests.
