# Combat Feel Pass

Status: 2026-10-07, branch `codex/combat-feel-pass`. Extends the working PvE slice
without SQLite schema changes or expanded item progression.

## Controls and combat

- WASD: movement/facing; I: inventory; E: nearest loot.
- Hold Space: repeated swings in front of the character, including without a target.
- Left click: optionally select a dog; clicking away clears selection.
- F: autoattack the selected dog with simple approach/turning.
  Manual movement or player/target death interrupts autoattack.

Clients send only `request_attack(sequence)`, not target ID, rotation, damage or
hit lists. The server validates session, living player, monotonic int32 sequence
and recovery. It reads attack from runtime equipment/stats, records server facing
and starts a swing. Entry loads runtime stats; item commits refresh them without
per-swing queries; see [persistence policy](persistence-policy.md). Misses still
consume combo stage/recovery. Player movement is blocked during recovery.

After windup, a mob-layer physics query resolves hits: 2.4 m reach, +/-65-degree
frontal sector, up to 1.2 m vertical difference and unobstructed world-layer line
of sight. Every eligible dog takes damage once per swing; client-selected targets
do not affect the result. Broad phase returns up to 64 colliders, sufficient for
the current four-dog arena.

| Stage | Windup | Recovery | Damage | Living mob reaction |
| --- | --- | --- | --- | --- |
| 1 | 120 ms | 450 ms | Equipment attack | 120 ms hit stun |
| 2 | 140 ms | 450 ms | Equipment attack | 120 ms hit stun |
| 3 | 180 ms | 700 ms | 1.5 x attack, rounded down | 350 ms hit stun and knockback |

A gap over 1100 ms between accepted swings resets to stage 1. Knockback begins
at 7 m/s away from the player and decays through server physics; world collisions
remain active. Death before impact cancels the swing. Replay/spam cannot bypass recovery.

These are prototype parameters, not claims about original Metin balance/limits.
Selection assists autoattack; skills are not implemented yet.

## Wild Dogs, navigation and death

The arena has four 120-HP dogs. AI remains `IDLE -> CHASE -> ATTACK -> RETURN`.
Aggro is 6 m, leash 12 m from home, attack reach 1.65 m. A dog deals 6 damage every
1200 ms while the player is living/visible and the dog is not hit-stunned.
Target loss or exceeding leash triggers return and HP restoration.

The server bakes a small-arena navmesh once from world-layer StaticBody3D geometry.
Each dog uses NavigationAgent3D and follows waypoints through CharacterBody3D.
Paths refresh every 200 ms; queries wait for navigation-map synchronization.
Obstacles are included in baking. This uses
[Godot's native navigation mesh](https://docs.godotengine.org/en/4.5/tutorials/navigation/navigation_using_navigationmeshes.html).
Player autoattack approaches the target directly without its own pathfinding.

Players have 100 HP. At zero, the server stops movement, cancels swing/combo and
blocks attack/pickup. The client shows a fallen capsule and countdown. After two
seconds, the server respawns at the start with 100 HP; the next combo starts at 1.
Dogs respawn after six seconds. These are automatic prototype respawns.

Each dog death creates a separate ground drop. Ownership uses actual damage.
Reservation 15 seconds, lifetime 120 seconds, full bags and atomic claims follow
[PvE](pve-ground-loot.md). Picked-up instances keep their UID across relog;
HP, positions and unclaimed loot remain runtime state.

## Presentation and limits

Dogs initially use procedural box placeholders. The player capsule moves its
weapon and shows a swing arc; the finisher has a gold effect. Hits flash the model,
briefly stop the mob and physically knock it back on the finisher. Mob/HP/combo/
respawn snapshots broadcast at 10 Hz; clients interpolate movement.

Final rigs/animations, PvP, skills, local prediction and AOI are not included in
this stage. Navigation targets a small static arena without crowd avoidance or
runtime navmesh rebuilds. Item progression needs its own next-stage scope.

## Verification

```powershell
& .\tests\run-combat.ps1
& .\tests\run-pve.ps1
& .\tests\run-spike3d.ps1
& .\tests\run-items.ps1
```

`run-combat` starts a server/two WebSocket clients on port 18098 with a test DB.
Run sequentially with `run-pve`, which shares that port. It checks two frontal
dogs and missed side/rear dogs, ignored target selection, spam/replay, combo
stages/reset, actual knockback, routing around the central obstacle, return/healing,
death during windup, post-death input/attack/pickup blocking and attacks after
respawn. Both clients verify replicated hits, finisher effect and the same player's
death/respawn. Markers: `COMBAT_SERVER_OK` and two `COMBAT_CLIENT_OK`.

Existing PvE still checks two players attacking one dog, ownership, full bag,
double pickup and UID durability after SQLite reopen. Full gateway/master/world
login was also verified through `tests/pve_session.tscn`: combat, ground loot,
pickup and exact UID after relog. Combo/loot previews in `.godot/verification` were
rendered and visually inspected.

Import and all 873 source scripts/scenes/resources loaded without parse errors.
Earlier certificate-store/exit-resource diagnostics remain. Manual assessment
of desktop controls/timings was left to the user at this stage.
