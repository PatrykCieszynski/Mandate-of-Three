# 3D spike - first stage

Status: 2026-10-07. The default Spike instance now runs a native 3D map.

## Implemented scope

- 32 x 32 m floor, walls and two StaticBody3D obstacles.
- CharacterBody3D player capsules with names, colors and facing markers.
- Perspective camera following the local character from above.
- WASD movement on XZ, gravity and 3D collisions.
- Login/handoff through existing gateway, master and world.
- Joining, player list, movement snapshots and disconnected-character cleanup.
- I inventory panel, UID equipment and SQLite instances;
  [item model and tests](item-instances.md).

Clients send a sequence number and Vector2 direction at 20 Hz. The server
normalizes direction, rejects non-finite values and repeated/stale sequences,
and runs CharacterBody3D physics at 60 Hz with a 5 m/s speed. Missing fresh input
for 250 ms stops movement. Window focus loss sends zero direction.
Vector3 + yaw snapshots return at 20 Hz; clients interpolate position/rotation.
The local player's first snapshot dismisses the loading screen.

Player identity comes from the RPC sender. Joining requires both the instance's
`awaiting_peers` entry and an authenticated PlayerResource in WorldServer.
Clients supply neither their position nor the controlled character ID.

## Migration boundary

Client/server `spike_instance_3d.gd` scripts adapt the existing instance lifecycle.
They inherit the session managers' expected types without running old Player/
LocalPlayer/Map2D or Vector2 StateSynchronizer behavior. Shared SpikeWorld3D uses
the same node path/RPC configuration on both sides. `InstanceResource.use_3d`
selects the server adapter; the client detects the loaded scene type.

Legacy HUD, combat, NPCs and interactions remained to be ported at this stage.
The spike has its own item panel, simple equipped-weapon model and a small movement/
player-count overlay. Old inventory/equipment does not handle the new map.
TinyMMO transport/sessions remain the foundation. The default technical 2D map
was replaced; remaining 2D classes still support quarantined modules.

3D position is runtime state. Reentry creates a capsule at its spawn; legacy
Vector2 `last_position` is not reinterpreted as 3D coordinates. Persistent position
requires an explicit model extension. No local movement prediction, AOI or snapshot
broadcast player cap exists yet. This first stage targets a small local spike.

## Files

| File | Responsibility |
| --- | --- |
| `source/common/gameplay/spike3d/spike_world_3d.gd` | Arena, shared RPCs, input validation, snapshots, camera and overlay. |
| `source/common/gameplay/spike3d/spike_character_3d.gd` | Capsule body/collision, server physics, client interpolation. |
| `source/common/gameplay/maps/spike/spike_map_3d.tscn` | Default Spike map scene. |
| `source/server/world/components/spike_instance_3d.gd` | Server instance adapter. |
| `source/client/network/spike_instance_3d.gd` | Client instance adapter. |
| `tests/spike3d_network.gd` | Two-client WebSocket test without changing accounts or DB. |
| `tests/run-spike3d.ps1` | Launch three processes and verify exit codes/test markers. |

## Verification

Godot 4.7.2 from the project's `.godot/`:

- Editor import: no new-script parse errors.
- All 873 source scripts/scenes/resources loaded after adding instances, PvE and combat.
- WebSocket test: server plus two headless clients, all exit 0. Verified two-player
  lists, movement seen by the other client, speed cap despite oversized direction,
  replay/NaN rejection, expired-input stopping, wall/obstacle collisions and
  disconnect cleanup.
- Full gateway/master/world entry: two local guest accounts/new test characters;
  both clients received 3D state and saw each other's movement. Full-login fixture/
  logs live in ignored `.godot/verification`.
- OpenGL arena/two-capsule preview generated and visually inspected.
- Manual desktop test: user confirmed two-client 3D operation on 2026-10-07.
  This is general confirmation, not reconnect or persistent-position verification.

Repeatable network/physics test from the project directory:

```powershell
& .\tests\run-spike3d.ps1
```

The test uses port 18097 and fixture session resources. It needs no running
gateway/master/world and does not test their authorization; full handoff was
verified separately. Logs stay in `.godot/verification`. Earlier Windows
certificate-store/exit-resource diagnostics remain; these are not new script
errors, but runtime is not entirely free of engine diagnostics.

## Next stage

ItemDefinition/ItemInstance, UID equipment and persistence are implemented.
The [PvE ground-loot slice](pve-ground-loot.md) adds combat/death/pickup.
Further priorities: [project direction](project-direction.md).
[Combat Feel Pass](combat-feel.md) expands this to directional combos, four Wild
Dogs, navigation and player respawn. Item Progression Slice follows that stage.
