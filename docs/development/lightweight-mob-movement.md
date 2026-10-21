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
# Separate instrumentation diagnostic; do not mix timer overhead into the A/B:
python tests/run-world-capacity.py --mob-movement light --profile on --scenarios 2:4 --layout dense --repeats 1 --warmup 1 --seconds 3
```

The flat contract joins ordinary smoke; Terrain3D is opt-in and requires the local
pinned addon/saved test scene. The fixture loads saved terrain/native collision
without the preview script; it never saves, sculpts, rebakes or touches the map
author's separate clone. Check script errors as well as markers/exit status.
Network runners use the existing port sequentially. No visible client is needed.

Artifact schema v3 adds `mob_movement`, fast/native counts, `movement_comparison`
and a policy suffix to summary/log keys. Profile coverage accepts a grounding
bucket instead of requiring native slide on every lightweight run. Movement A/B
requires profiling off; profile overhead is measured separately. All existing
W0/W1 timings/interpretation still apply. No performance threshold is added to CI.
Control is current same-commit native behavior, not historical W1 numbers.

Large runs stay opt-in and sequential. Report median physics work and tick/frame
tails, observed Hz, CPU/RSS and fallback counts. Both variants retain player
physics, AI, BODYs and the same snapshot proxy. These synthetic actors are not
connected clients; no live economy or capacity guarantee follows from the result.
