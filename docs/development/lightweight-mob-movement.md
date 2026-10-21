# W4a — experimental lightweight mob movement

User-approved experiment after W1, before the player-controller W2/W3 work.
**Native movement remains the default.** This does not promote a new controller
or complete the wider Terrain3D/gameplay parity gates.

## Selection and rollback

Add `--dev-light-mob-movement` to the **World process** command line. Only a
server-mode `MobActor3D.setup_mob()` accepts it. No client/RPC/configured-session
identity can select this policy. Removing the flag and restarting returns to the
original path; no persistence migration, new worker or protocol is involved.
Clients continue interpolating authoritative snapshots. Player motion is unchanged.

### Terrain3D height provider (follow-up within W4a)

An explicitly assigned `GameWorld3D.mob_grounding_terrain` path selects a shared,
map-owned height provider. Empty path keeps the ray provider for box maps,
dungeons or mixed surfaces. Both are invoked per tick; there is no height cache,
cadence scheduler, batching scan or Y interpolation in this experiment.

Verified against installed Terrain3D **1.0.2** and its pinned upstream source:
[`Terrain3DData::get_height`](https://github.com/TokisanGames/Terrain3D/blob/v1.0.2-stable/src/terrain_3d_data.cpp#L650)
accepts **global** positions, bilinearly interpolates heights and returns NaN for
holes/missing regions. Do not convert the argument to terrain-local coordinates.
The plugin [resets its local transform](https://github.com/TokisanGames/Terrain3D/blob/v1.0.2-stable/src/terrain_3d.cpp#L886);
the provider rejects non-identity global terrain transforms instead of guessing
translation/scale semantics. Translated actor parents still use global positions.

One height query per tick replaces the ray. Non-finite data or a rise/drop beyond
the same 0.4/0.75 m bounds requests native handling. Actor feet keep their existing
model/defending offsets and 0.002 m clearance. Knockback remains native. Direct
sampling is a point/bilinear approximation, not capsule or triangle parity.

Use this provider only for a declared terrain surface. A heightmap cannot
identify a low bridge, a different floor or an overhang at the same XZ. Select
ray grounding on mixed-surface maps; automatic surface identity is deferred.
A tall bridge may trigger the height bound/fallback, but that is not a general
bridge detector. The experiment does not silently opt all Terrain3D maps in.

The same `CharacterBody3D`, movement BODY on layer 4 and defending capsule remain.
Ordinary mobs already ignore other mobs/players/scenery while moving (mask 16,
floor only); this experiment preserves that policy. Player blocking, attack
broadphase, narrow-phase defending geometry, HP, reactions, rewards, AI/pack and
replication rules are retained. It does not disable hitboxes to save motion cost.

## Fast path and grounding

`mob_grounding_3d.gd` is a small server grounding boundary. One native ray tests
floor layer 16 at the desired XZ, from current feet +0.4 m to feet -0.75 m.
Valid support gives height +0.002 m clearance. Steep upward support outside the
body's normal floor angle requests native handling; bounded descent is allowed.
It samples actual collision, so saved Terrain3D, box floors and physics holes
share the same path; it does not invent a flat height or bypass terrain data.

On valid support the server assigns XZ + sampled Y without `move_and_slide()`.
This is a **point-foot approximation**, not native capsule support. If the ray
misses, the slope is ambiguous, or the actor is airborne, the existing native
motion/gravity handles the tick with the original intention. This matters: one
saved downhill route has no point-ray hit where the capsule still has support.
Stopping all planar movement there incorrectly prevented a legitimate descent.

Knockback always retains native `move_and_slide()` and its temporary scenery
mask, damping, hit lock and collision recovery. The candidate does not implement
a second displacement solver. `light_grounded_ticks` / `light_native_ticks` are
server-local experiment counters (never replicated) showing actual fast-path
usage vs fallback, including knockback. Native `is_on_floor()` can be stale during
the direct-position fast path; do not treat it as the candidate grounding signal.

Known differences/open parity: small height steps may snap, point support does
not reproduce capsule support near all edges, and platform attachment/ceilings/
arbitrary initial penetration or the full cliff/stair matrix are not implemented
by the fast path. Grounding fallback preserves native behavior on missed support,
but this is not proof of general terrain equivalence. Keep the switch opt-in.

## Verification and paired measurement

```powershell
# Native + candidate, floor/hitbox/knockback/death + saved Terrain3D routes:
& ./.godot/Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=world-server res://tests/mob_movement.tscn --with-terrain --quit-after 3000
& ./tests/run-pve.ps1 -LightMobMovement
& ./tests/run-combat.ps1 -LightMobMovement
& ./tests/run-combat.ps1 -LightMobMovement -Scene combat_trace_network -MarkerPrefix TRACE
# Same-commit unprofiled native/light, alternate order, three pairs per cohort:
python tests/run-world-capacity.py --mob-movement compare --scenarios 100:200,250:500
# Three-way API/movement comparison: real Terrain3D data, common box collider.
python tests/run-world-capacity.py --terrain --terrain-collision box --mob-movement compare --mob-grounding compare --layout dense --scenarios 100:200,250:500
# Separate full native Terrain3D collider diagnostic (can be very slow):
python tests/run-world-capacity.py --terrain --mob-movement compare --mob-grounding compare --scenarios 2:4 --layout dense --repeats 1 --warmup 1 --seconds 3
# Separate instrumentation diagnostic; do not mix timer overhead into the A/B:
python tests/run-world-capacity.py --mob-movement light --profile on --scenarios 2:4 --layout dense --repeats 1 --warmup 1 --seconds 3
```

The flat contract joins ordinary smoke; Terrain3D is opt-in and requires the local
pinned addon/saved test scene. The fixture loads saved terrain/native collision
without the preview script; it never saves, sculpts, rebakes or touches the map
author's separate clone. Check script errors as well as markers/exit status.
Network runners use the existing port sequentially. No visible client is needed.

Artifact schema v4 adds `mob_movement`, grounding/provider and terrain-collider
selection, fast/native counts, `movement_comparison` and policy/provider suffixes
to summary/log keys. Profile coverage accepts a grounding
bucket instead of requiring native slide on every lightweight run. Movement A/B
requires profiling off; profile overhead is measured separately. All existing
W0/W1 timings/interpretation still apply. No performance threshold is added to CI.
Control is current same-commit native behavior, not historical W1 numbers.

`--terrain` creates four disposable native flat Terrain3D data regions and uses
the full Terrain3D collider by default. `--terrain-collision box` explicitly keeps
the same box support for all three variants and disables Terrain3D collision,
while height queries still use the real native data API. This isolates the
movement/grounding change from full-heightfield collision cost; it is not a
capacity measurement on a full Terrain3D map. The saved-terrain route tests and
the full-collider diagnostic cover that separate boundary. Never merge these
cohorts or present their results as equivalent workloads.

Large runs stay opt-in and sequential. Report median physics work and tick/frame
tails, observed Hz, CPU/RSS and fallback counts. Both variants retain player
physics, AI, BODYs and the same snapshot proxy. These synthetic actors are not
connected clients; no live economy or capacity guarantee follows from the result.
