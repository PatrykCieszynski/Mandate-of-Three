# Gameplay

Gameplay rules and server-authoritative player interactions. These describe the **current implementation** unless marked as future proposals.

- [Combat and Warrior](combat/README.md)
- [Mobs and packs](mob-packs-v1.md), [horn taunt](horn-taunt-v1.md), [Metin encounters](metin-encounter-v1.md), [ground loot](pve-ground-loot.md)
- [NPC interactions](npc/README.md)
- [Character XP](character-xp.md), [item progression](item-progression.md)
- [Camera controls](camera-v1.md)

For approved *future* design rather than current code, see [gameplay direction](../decisions/gameplay-direction.md). Account-wide economic ownership and durable loot contracts live in [Economy C1–C5](../architecture/economy/README.md).

## Party V1 — open-world runtime

Party is owned by the single World Process, keyed by persistent character IDs,
independently of MapInstance/CH and the legacy dungeon-only `GroupService`.
Neither party membership nor invitations are persisted across World restart.
CEF's draggable **Party · P** window provides invite/accept/decline, members and
levels/HP, leader transfer/kick/leave, and leader-only EXP/drop mode selection.
The candidate selector lists up to 64 online players in the current instance;
server authorization still owns identity, permissions and all joining rules.
HP-only updates preserve selection controls; online party HP can be shown across
local CH even though rewards cannot cross them. P or the close button hides the
window; incoming invitations reopen it. Reload gets the current full snapshot.

- Maximum 8 members. Joining/acceptance checks the current highest-to-lowest
  level gap is at most 15. Existing members are never removed by level-up.
- Logout/disconnect keeps a visible offline seat indefinitely, still counting
  against the 8-member limit. Same-character reconnect under a new peer restores
  it automatically. Offline members receive no EXP, Yang or rights to new drops.
  Membership ends only through explicit leave, kick, party dissolution or World
  restart. An offline leader keeps leadership. On final leader departure, the
  lowest online character ID inherits it; if nobody is online, the lowest
  remaining character ID is used. There is no offline-expiry timer or database
  persistence.
- Membership survives local channel handoff. Reward recipients must have a
  current actor in the source MapInstance, not be transferring and be within
  `[runtime] party_reward_radius=40` metres in `data/config/world_config.cfg`.
  Offline, absent and distant members do not dilute the eligible members' shares.
  Dead but present members remain eligible. This is PvE party support, not a
  new PvP allegiance policy or a dungeon admission/lobby implementation.

### Reward entitlement and membership during combat

Each accepted damage contribution captures its competitor: solo character or
stable party ID. Earlier solo damage never becomes party damage on joining;
earlier party damage stays with that party after leaving. A party is one
competitor, including after roster changes. A party's recipient roster and EXP /
drop modes freeze at its first hit on that enemy; later joiners start receiving
party rewards on newly engaged enemies. Leavers lose eligibility for that old
party claim. This prevents switching modes or adding a high/low character at the
last hit to redistribute earlier work. Levels/range/instance are evaluated at
reward time. Ordinary mobs choose the highest aggregate competitor damage;
competitor-key ordering resolves ties deterministically. Solo-only fights retain
the existing highest-character-damage/tie and offline reservation behavior.

### EXP, ground items and Yang

Pure `party_exp.gd` / `party_drop.gd` strategies return allocations/rights and do
no RPC, SQL or mutations. `party_rewards.gd` applies decisions through existing
World progression, ground custody and wallet owners.

- EXP `equal`: weight 1; `by_level`: current level; `carry`: weight
  `15 + 3 * (highest eligible level - own level)`. At level differences 0/5/10/15,
  the lower player's weight relative to the highest is 1/2/3/4. This is catch-up,
  not equal percentages of XP bars. One strength constant controls tuning.
- Integer allocations use largest remainders with character-ID tie breaks.
  The full pool is conserved. Existing `award_experience()` and level-up/XP
  curve remain authoritative; recipients need not personally deal damage.
- Item `round_robin`: sorted eligible IDs, one shared party cursor; it advances
  only after an actual successful item spawn. `by_damage`: highest eligible
  individual contribution, lowest-ID tie/fallback. `free`: one UID reserved for
  the frozen eligible party members who still belong to that party.
- Every item stays on the ground. Existing protection expiry, item lifetime,
  capacity/revision/custody checks, in-flight claim lock and immediate atomic
  PostgreSQL pickup remain in charge. Rights are checked at admission; later party
  changes do not roll back an already admitted economic claim. There is no copy
  per member.
- Yang always splits equally, independently of item mode. Each nonzero share is
  a reserved GroundCurrency stack; their sum equals the original Yang pool.
  Picking a share up uses the same wallet RAM/pending/checkpoint path. Normal
  reservation expiry still makes unattended ground shares public.

Metin/boss shared-pool policy is described in [Metin encounters](metin-encounter-v1.md).
Party remains single-World, runtime-only; cross-host membership and durable party
recovery are not implemented. Client/server build 0.31.0 ships the new Party RPCs.

### Verification

Default smoke includes `party_v1`; the two-client `party_network` fixture covers
actual command RPCs, passive-member XP, Yang conservation, item reservation,
no-drop cursor behavior, kicked-member free-drop denial, offline reward exclusion,
competing pickups and one shared Metin item pool. Core coverage also checks
indefinite offline seats/leadership, online-preferred succession, late-join reward
exclusion and leave/solo-hit/rejoin contribution conservation.
Existing local-instance and World-RPC fixtures also cover party continuity across
real CH transfer and delayed old-session disconnect. The PostgreSQL ground runtime
fixture exercises party-free rights, membership loss, blocked claims, one UID,
failed COMMIT and response-loss recovery on a disposable cluster.
Native CEF acceptance uses `run-combat.ps1 -Scene party_network -MarkerPrefix PARTY
-NativeClient1`: real invite/mode commands through the CEF bridge and roster reload.
It uses programmatic DOM activation; manual physical input/IME and gameplay feel
remain separate verification. Export checks preserve server/headless boundaries.
