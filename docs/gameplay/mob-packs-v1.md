# Mob packs and straight-line AI v1

World owns all mob spawning, runtime IDs, XYZ movement, targeting, HP, death and
replacement. This is a focused mob runtime, not a generic actor or encounter factory.
The Metin lifecycle, reward/contribution rules and persistence policy stay intact.

## Content and authoring

`source/common/gameplay/mobs/` contains `MobDefinition`, `MobSpawnEntry`,
`MobSpawnPoint3D` and the map-local `MobPackRuntime`. Ten `.tres` definitions
cover the original four dogs and six additional wolf/bandit profiles.
`mob_key` is content identity; `display_name` is presentation text.
The original four dogs still use the optional `stray_dog` visual; wolves
and bandits use curated `wolf`/`barbarian_*` visual IDs with local-only
models and repo-owned fallback placeholders. HP/damage/speed/visual are copied
through one `CombatEndpoint3D.spawn_mob` entry point. `MobSpawnEntry.valid()` requires
the exact canonical resource registered in `MobDefinitions`, not merely a valid
resource with a matching key. Unregistered keys and duplicate resources using an
existing key are rejected before any pack member is spawned, including in release
builds. Register new definitions and reference those same resources in map/wave
content; runtime encounter copies must preserve their shared mob definitions.

A map authors Marker3D nodes with the `MobSpawnPoint3D` script. Each supplies
`members: Array[MobSpawnEntry]`, spawn/wander/leash radii and a per-member respawn
interval. Counts are 1–100 per entry. Invalid content is rejected at load. Spawn
and wander sample a uniform disk around the anchor, with independent timers.
No separate MobPackDefinition, leader or formation system is introduced.

The production graybox authors six pack markers in `first_region_3d.tscn`:

| Area | Pack compositions | Total |
| --- | --- | --- |
| Outskirts | 10 Forest Wolves; 10 Forest Wolves + 3 Dire Wolves + 1 Wolf Alpha | 24 |
| Old Road | 10 Road Bandits + 6 Bandit Raiders; 10 Road Bandits + 7 Bandit Raiders + 1 Bandit Captain | 34 |
| Stone Hollow | 14 Feral Dogs + 8 Hollow Hounds; 14 Feral Dogs + 10 Hollow Hounds | 46 |

There are 104 open-world actors before Metin waves. These are density test data,
not final balance. Spawn radius is 5–6 m, wander 9–10 m, leash 15–18 m and each
killed member is replaced after 15 seconds. The hub is outside the wander +
proximity aggro envelope. Map code contains geometry, not mob combat stats.

## Runtime behavior

One combat-owned allocator issues all `mob_instance_id` and `pack_instance_id`
values for the map lifetime. The existing `mob_id` property is a runtime-ID alias
for combat/target consumers. IDs are never DB identities and are not reused.
A spawn point keeps its pack identity; each replacement gets a new actor ID.

Melee, including a killing hit, recruits the
living pack on the attacker. Dead/disabled actors are excluded. Other packs do
not inherit the target. Aggro refuses a target already outside that pack's leash.
Dog definitions disable `proximity_aggro`: walking nearby does not start combat.
Other future definitions can opt into natural proximity detection.
Members move independently: `IDLE -> WANDER`, `CHASE -> ATTACK`, `RETURN`, `DEAD`.
Chase and return use straight XZ directions, without NavigationAgent3D, navigate
or periodic repathing. Wander chooses a local point, moves and waits with jitter.
Leash compares both the member and its target against the shared pack anchor.
Return picks a separate destination per member inside the pack wander disk, once
on entering RETURN. It restores HP, clears contribution/target and resumes
idle/wander there; members do not collapse onto the anchor.

Movement still uses server gravity, floor contact and move_and_slide. Ground
bodies expose bits 1 + 5 (`17`): bit 1 remains the player's scenery/camera/NPC
navigation geometry; bit 5 (`16`) is floor-only movement for mobs. Walls/props
expose bit 1 only. Player mask remains 1, mob movement mask is 16, and mob hurtboxes
remain bit 3 (`4`). Mobs can pass through props; melee/attack line-of-sight still
uses scenery. New terrain must expose the floor bit. There is no client Y authority.
Shared navmesh baking remains for NPC approach; mobs do not query it.

Death schedules one replacement ticket containing the definition and due time.
Other members stay alive. Corpse cleanup and respawn timers are independent;
cleanup removes the old actor, and the ticket creates a fresh actor at a random
spawn point. Pack state and all timers are RAM-only. Scene teardown drops them.

## Metin and replication

`MetinWaveDefinition.members` uses the same entry resources. The 75/50/25 waves
still contain 3 Wild Dogs, 4 Wild Dogs, then 3 Wild Dogs + 1 Metin Elite.
Each wave creates its own runtime pack, immediately aggroed on the stone attacker
regardless of passive proximity policy, through the same entry point, tagged with
`source_metinstone_id`, no replacements and the existing 180-second lifetime.
Surviving waves remain after stone death and expire independently, including when
a later stone is active. Empty temporary packs are removed. There is no navmesh
synchronization requirement for stone damage or wave creation.

Snapshots still use the existing transport. The 104-actor join burst exceeded
Godot's default WebSocket buffer, so the common endpoint configures bounded 1 MiB
inbound/outbound buffers before connecting on both client and server. The network
fixtures use that same setup. This is capacity configuration, not snapshot/AOI
redesign; it increases per-connection buffer capacity. The engine properties are
listed in [Godot's WebSocketMultiplayerPeer API](https://docs.godotengine.org/en/stable/classes/class_websocketmultiplayerpeer.html).

Complete mob records use the following compact format:

```text
[instance_id, position, yaw, hp, numeric_state, mob_key, source_metinstone_id, down_remaining_ms, get_up_remaining_ms]
```

`MobSnapshot.Field` defines the indices. `MobState.Value` defines stable wire
values: IDLE=0, WANDER=1, CHASE=2, ATTACK=3, RETURN=4, DEAD=5, DISABLED=6.
Server AI uses the same shared numeric states. The shared
`MobDefinitions.resolve(mob_key)` registry supplies client display name, maximum
HP and visual ID. Register new content in that registry before spawning it;
unknown keys are warned about once per key for the endpoint lifetime and skipped
rather than rendered with fake metadata.
Client and server content/protocol must ship together; the old dictionary shape
is not supported.

Damage, speed, home/pack anchor, pack ID, leash, aggro and respawn state are not
replicated. The source stone ID remains for encounter provenance/debugging.
World actors contain no DogVisual or name/HP Label3D nodes and do not format label
text during physics ticks. Clients create actors from authoritative records and interpolate; they do not
simulate spawning, wandering, leashing or respawn. The target resolver clears
dead/removed identities and disables autoattack; a replacement cannot revive an
old selection. The 1 MiB buffers remain unchanged.

### Mob interest and sparse reliable updates

Each MapInstance owns its own mob interest grid and per-peer sent-state baseline.
The grid uses XZ cells and exact horizontal distance, independent of camera
position or client-supplied targets. The older TinyMMO grid is coupled to 2D
StateSynchronizer/PathRegistry entities; the dedicated mob owner uses the same
cell-query approach without importing that legacy replication stack.

World's existing reliable ordered combat-state RPC still runs at about 10 Hz.
Its `mob_ids` array is the complete authoritative visible set; `mobs` contains
only new or changed records. An absent changed record retains an actor, while
absence from membership removes it. New entry always includes a complete record.
Hysteresis uses a smaller entry radius than exit radius to avoid boundary churn.

Changed positions/yaw have a separate per-peer/per-mob minimum interval. State-only
records use null POSITION/YAW to omit transforms; the client merges them with its
existing baseline before presentation. No record is sent for an unchanged idle
mob. Motion that stops inside the rate window is sent on the next eligible
combat publication, so the final position is not lost. HP, AI state, death and
hit-lock changes do not wait for the motion deadline. Native interpolation remains
unchanged; physical feel at the reduced motion rate still needs manual validation.

The client-facing combat state reconstructs the complete visible `mobs` list;
UI/target consumers never have to interpret wire deltas. Disconnect/attachment
initialization clears the peer baseline. A failed RPC enqueue also invalidates
the baseline so the next publication bootstraps it again. New MapInstances have independent
baselines and client actors, so entry/re-entry receives fresh authoritative state.
There are no new spawn/despawn/resync RPCs: correctness relies on the existing
reliable ordered connection. Client and server must ship this protocol together.
The game build version is advanced for the wire change so the existing Gateway
exact-match login/handshake gate rejects older published clients. Restart the
normal roles and clients together; mixed-version rolling deployment is unsupported.

World `[runtime]` configuration defaults in `data/config/world_config.cfg`:
`mob_aoi_enter_radius=60`, `mob_aoi_exit_radius=72`, `mob_aoi_cell_size=32`
(metres), and `mob_position_interval_ms=200`. They are validated at startup;
entry must not exceed exit, dimensions are positive integers and the position
interval is 50–2000 ms. Actual motion delivery is also bounded by combat cadence.
These are initial tuning values, not measured capacity limits.

Only mobs use this interest policy. Player replication, Metin state, ground loot,
combat event broadcasts, AI and authoritative hit testing are unchanged. AOI does
not put distant mobs to sleep or alter gameplay authority. Unreliable movement,
quantization, event interest and broader entity AOI remain separate work.

Verification: default smoke includes `mob_interest`; the existing network runner
accepts `-Scene mob_interest_network -MarkerPrefix AOI` for two observers,
empty deltas, boundary hysteresis, death, removal and re-entry. Existing local-map
and session suites cover recreation/instance isolation; no MMO capacity claim is
made from these focused fixtures.

### Serialized payload measurement

`mob_packs.gd` compares the frozen previous dictionary shape with the production
compact encoder for the same actors using Godot `var_to_bytes`. These numbers
measure only the complete `dogs`/`mobs` section, including its outer dictionary;
they exclude other combat fields, RPC framing and WebSocket overhead.

| Actors | Previous | Compact | Reduction |
| --- | --- | --- | --- |
| 50 | 20,108 bytes / 19.64 KiB | 4,904 bytes / 4.79 KiB | 75.6% |
| 100 | 39,908 bytes / 38.97 KiB | 9,704 bytes / 9.48 KiB | 75.7% |

Measured headlessly with Godot 4.7.2 on Windows. This is roughly a 4.1x reduction
including the two reaction recovery fields for this fixture, not a total bandwidth or frame-time benchmark. Names, source
IDs and composition affect byte counts. The regression check requires a broad
reduction, not these exact numbers.

## Verification and remaining manual pass

Default smoke includes `mob_packs.gd`: mixed composition, ID uniqueness, pack-only
aggro/proximity, anchor leash/reset, one member's replacement, old-target invalidation,
Metin provenance/expiry, a short 50-actor AI tick, compact serialization round trips
(including every AI state) and 50/100-actor payload sizes. This is not a benchmark.
`run-first-region`, `run-metin`, `run-combat` and `run-metin-network` cover production
content, stone thresholds, collision policy, real melee pack aggro and two-client
snapshot/reward behavior. Test fixtures use the small legacy arena where appropriate.

Restart World and reconnect clients to load the new data/protocol. Play 10–15 minutes:
attack one outskirts member, pull the pack, kill several, leave leash, return and
observe individual replacements; continue through mixed packs and a Metin wave.
Assess density, readable combat, travel gaps and client frame time. Headless checks
do not prove native render performance at 104 actors. No balancing or additional AI
framework should precede that manual pass.
