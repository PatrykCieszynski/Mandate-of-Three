# World 3D actor simulation hotpaths (production candidate)

This branch changes **only** server actor simulation, overlap detection and
mob pack lifecycle. No Economy, database or networking implementations are
changed. The objective is to remove repeated physics work before contemplating
a rewrite of the Godot World.

## Changes

1. **Player/mob overlap**: existing upright, unit-scaled capsule actors are
   indexed in a 4m spatial hash, rebuilt once per physics frame. Capsule
   intersection uses the exact geometry of two vertical line-segment capsules,
   avoiding a new `intersect_shape(max_results=256)` query for each player.
   Unknown/rotated/scaled colliders retain the original physics-space query.
   Previous blocking and temporary exception behavior in `PlayerActor3D`
   is preserved.
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

The smoke suite includes `mob_hotpaths.tscn`: it validates standard capsule
overlap, negative cases, tilt fallback, actual floor settling, travel distance
and idle stability. `mob_packs.tscn` covers respawn identity, deadlines,
replacement counts and temporary Metin pack expiry.

Before merging, check slopes, stairs, map seams, knockback, attack advance,
stun and moving platforms in a real gameplay session. Do not infer performance
improvements from passing functional tests; repeat the same headless capacity
run with the unmodified main build and identical machine configuration.
The branch does **not** include netcode/AOI changes.

For collision correctness, the optimized capsule path is strictly for
Godot-created upright unit-scale capsules. Introducing a new movement shape,
non-unit transforms, or changing mob collision masks should trigger a review
of the broadphase fallback.
