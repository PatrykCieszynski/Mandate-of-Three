# World 3D actor simulation hotpaths (production candidate)

This branch changes **only** server actor simulation, overlap detection and
mob pack lifecycle. No Economy, database or networking implementations are
changed. The objective is to remove repeated physics work before contemplating
a rewrite of the Godot World.

## Changes

1. **Player/mob overlap — scripted index reverted**: the first candidate
   used a 4m GDScript spatial hash and capsule checks. In the 250-player /
   500-mob dense baseline, this path took ~98 ms/tick in the profiled run
   and dominated player simulation. Revert it in favor of Godot's native
   `intersect_shape(max_results=256)` broadphase; reuse the query parameter
   object and preserve collision and recovery behavior. Any future attempt
   at replacing the physics query must be benchmarked in the same density
   before it is proposed for production.
2. **Mob movement**: ordinary grounded motion accumulates horizontal
   displacement over two physics frames; actor IDs stagger the native
   `move_and_slide()` calls to ~30 Hz. AI/combat decisions continue to run
   every physics tick. Stuns, knockback, airborne motion and moving platforms
   run their original full-rate collision solve. Stationary grounded mobs only
   resample floor contact every sixth tick. This is a *small temporal fidelity
   change* and should be assessed in combat/terrain tests.
3. **Pack lifecycle**: the expensive scan and copy of every pack's
   `replacements` each tick is replaced by scanning only packs with pending
   respawns. Empty non-respawning packs are retired during mob removal.

## Required validation

```powershell
./tests/run-smoke.ps1
./tests/run-pve.ps1
./tests/run-combat.ps1
```

The smoke suite includes `mob_hotpaths.tscn`: it validates native
player/mob overlap, actual floor settling, travel distance and idle stability. `mob_packs.tscn` covers respawn identity, deadlines,
replacement counts and temporary Metin pack expiry.

Before merging, check slopes, stairs, map seams, knockback, attack advance,
stun and moving platforms in a real gameplay session. Do not infer performance
improvements from passing functional tests; repeat the same headless capacity
run with the unmodified main build and identical machine configuration.
The combined experiment branch also carries AOI from PR #20; the AOI code
is separate from these simulation hotpath changes. The simulated-only load
fixture overrides network broadcasts and cannot measure AOI throughput.
