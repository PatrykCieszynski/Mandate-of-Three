# Open-MT2 as a reference for Mandate of Three

Analysis date: 2026-10-07. Repository: [willianmarquess/open-mt2](https://github.com/willianmarquess/open-mt2).
Analyzed snapshot: `8d8800d470f0b69221886723eb5877a2ed9d9d8d`, dated 2026-08-18,
`Merge pull request #262 from dimabirca/fix/non-weapon-melee-attack`.
Links below are pinned to that commit. This is a historical analysis of the fork
before subsequent 3D/item/combat changes; current priorities are in
[project-direction.md](project-direction.md).

## Conclusion and scope

Open-MT2 is useful as a server-rule reference for item instances, inventory,
attack validation, mob behavior and ground loot. Mandate retains TinyMMO transport
and session lifecycle and implements its own gameplay domain in Godot. Open-MT2
is neither a runtime dependency nor a second backend.

This is source/selected-test analysis, not a full audit. Reviewed Item/ItemState/
Inventory, move/drop/pickup/shop services, item persistence/cache, player attacks
and PvE damage, movement validation, Behavior/Monster, DropManager and quest/packet
documentation. Dependencies, server, MySQL/Redis and Open-MT2 tests were not run.
Risks are code observations, not reproduced exploits.

[README](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/README.md) describes an educational project allowing deviations from original
Metin. Treat it as design material rather than a compatibility specification.

## What the code contains

| Area | Observed implementation | Application to Mandate |
| --- | --- | --- |
| Items | Prototype vnum, separate dbId, owner, position, window, amount, three sockets and seven attribute type/value pairs. | Separate ItemDefinition/ItemInstance; assign instance identity before inventory insertion. |
| Inventory/equipment | 5x9 page grids, multi-cell items, dedicated equipment slots, equip/unequip events, movement and stack splitting. | Reuse ownership/slot/stack rules conceptually; grid size is a UI decision independent of 3D. |
| Bonuses | Instance fields persist and appear in packets; equipment applies iterate prototype bonuses. | Implement our own affix generation/instance stats. Persisting a bonus alone is insufficient. |
| Upgrade/reroll | refineId/refineSet and prototype metadata exist; no refine or attribute-reroll service found in reviewed src. | Design our own UpgradeService/RerollService; do not assume ready-made +0...+9 behavior. |
| Combat | Client selects target/skill; server calculates damage, checks state/rate and melee distance. PlayerBattle PvP is TODO. | Own AttackRequest with world/range/time/equipment validation, initially PvE. |
| Movement | Per-request distance cap, travel budget for position reports and rejection correction. | 3D server validation including collisions/height. |
| AI | Idle/wander, target search, follow/attack/return, stun, group reactions and damage contributions. | Small mob state machine, NavigationAgent3D and server timers. |
| Loot | Rank/level common drops, default mob drop, gold, chance modifiers and separate ground entity. | Simple DropTable/GroundLootInstance independent of artwork. |
| Pickup | Entity type, same area, distance, loot rights, full inventory and duplicate protection. | Preserve invariants; use owner UID rather than name. |
| Persistence | Separate item records, update/delete queues and flush queue restoration on error. | Own SQLite adapter and atomic item/cost operations. |
| Quests | TypeScript classes, states, LOGIN/KILL/CLICK events, player/NPC facades and dialogue mechanisms. | Domain-event inspiration; quests stay outside the first spike. |

Sources: [Item](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/item/Item.ts), [ItemState](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/state/item/ItemState.ts), [Inventory](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/inventory/Inventory.ts), [MoveItemService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/MoveItemService.ts), [PlayerApplies](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/player/delegate/PlayerApplies.ts), [PlayerBattle](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/player/delegate/battle/PlayerBattle.ts), [quest docs](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/docs/quests.md).

## Main difference from the fork at analysis time

`source/common/gameplay/items/inventory.gd` already had separate
`slot_uid -> {id, a}` entries, but:

- id was the ContentRegistryHub definition; next_uid() assigned a local number
  from current bag contents rather than a durable global item UID.
- normalize() preserved id, a and pinned. Upgrade/affix/socket fields needed
  explicit inclusion or they would disappear when loading.
- EquipmentComponent/item.equip operated on definition IDs;
  remove_one_by_id() selected the first matching instance.
- Equipment stored slot -> item_id; stats/appearance came from the Resource.
- RewardService granted items directly to kill participants, without ground loot.

Two same-definition swords with different bonuses were therefore not addressed
correctly by that equipment flow. Adding bonuses to Resource would mutate a shared
definition. Domain, endpoints, persistence and UI projection needed rework
independently of changing Node2D into Node3D.

## Useful patterns and their limits

### Items and inventory operations

Item.getId() returns prototype ID; getDbId() returns record identity. New items
receive dbId after INSERT. Our ItemInstance should receive its UID at creation
and retain it across equip, loot and saves. Bag positions/runtime network entity
IDs should not substitute for this identity.

Proposed implementation contract:

```text
ItemDefinition: definition_id, name, slot, base_stats, stack_limit, affix_pool
ItemInstance: uid, definition_id, owner_character_id, location, position,
              amount, upgrade_level, affixes[], sockets[], revision
Equipment: slot -> item_uid
```

UID/owner_character_id are independent of connection peer_id. Location identifies
one current place. Materials can stack when instance state matches; individually
rolled gear remains nonstackable. Fixed attributeType0...6 fields and a definition
per upgrade level are unnecessary; explicit upgrade_level and affix collections
better fit the PoE-lite plan.

In this snapshot Item.create() zeroes instance attributes; PlayerApplies.addItemApplies()/
removeItemApplies() read prototype item.getApplies(). Random-bonus fields do not
prove implemented rolling or stat effects: a significant gap for our goal.

### Attacks and movement

[CharacterAttackService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/CharacterAttackService.ts) resolves the target's virtual ID; [Player.attack](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/player/Player.ts#L643) checks state/time;
distance validation lives in [PvE strategy](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/player/delegate/battle/PlayerBattleAgainstMobStrategy.ts#L181). The responsibility split is useful,
but Metin damage formulas/units are not our intended balance.

The historical proposal carried target, action type and request number; the server
would check instance, both actors' life, cooldown, range/collision and equipment.
Clients play animation/result effects. Multi-target attacks should derive from one
legal action/AoE. Open-MT2's test allows a first hit on a new target during cooldown;
its throttle is not a global per-swing cap to copy without a design decision.
Later Mandate decisions select directional melee without a required target;
see [Combat Feel Pass](combat-feel.md).

[CharacterMoveService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/CharacterMoveService.ts) calls Player.isMoveAllowed(). Position-jump/travel-budget checks exist,
but MOVE skips the budget; the code distinguishes movement destinations from
current-position reports. Do not port mechanically into 3D. Our server must
control speed/allowed space; replication needs explicit intent/state/correction.

### AI, contribution and loot

[Behavior](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/mob/behavior/Behavior.ts) is a useful minimal list: roam, acquire, chase, attack, return.
Movement uses planar map-blocking checks. Map states onto NavigationAgent3D without
copying Metin coordinate/unit algorithms.

Behavior.onDamage() compares whole damageMap entry objects rather than .damage
values. Monster.reward() associates the drop with the current target. This is not
a verified highest-contribution rule. Keep aggro_target, killer, contribution list
and loot_owner separate with explicit rules. Source: [Monster](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/mob/Monster.ts).

[DropManager](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/manager/DropManager.ts) combines several drop sources and bonuses/level deltas. The spike needs
one mob, a simple chance table and one ownership rule, not premium, empire
privileges or gold multipliers.

[DroppedItem](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/item/DroppedItem.ts) reserves loot for 15 seconds and despawns after 30; these are examples,
not proposed balance. [PickupItemService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/PickupItemService.ts) checks area, distance and owner. markTaken()
before the first await prevents duplicate pickup in that process. However, world/
bag state changes before DB persistence, so the flow alone cannot survive save
failure. Our reservation/commit path must handle errors.

### Persistence and economy

[ItemManager.flush](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/manager/ItemManager.ts) restores its queue after failure and should retain updates added during
await. This is useful cache handling, but Promise.all of independent writes is
not one transaction; some records may persist before failure.

[PrivateShopService.buy](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/PrivateShopService.ts#L288) checks exact instance, bag space and currency cap. Item/gold change in
RAM, and buyer/seller save separately. [SaveCharacterService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/domain/service/SaveCharacterService.ts) returns Promise.allSettled results;
buy does not inspect rejected results before OK. Do not adopt this as a safe
economy transaction. Upgrade/reroll should persist instance changes and consumed
cost in one SQLite transaction, acknowledging success after commit. Two-player
trade is a later stage.

## Remaining TinyMMO dependencies

| Dependency | Recommendation after analysis |
| --- | --- |
| Login/auth/gateway/master/world lifecycle | Keep; verify actual two-client login. Open-MT2's different stack/protocol does not replace it. |
| ContentRegistryHub/static Resources | Keep definition registry role; rebuild gameplay definitions without instance state in Resources. |
| Inventory/equipment/item.equip/JSON persistence | Rework together around instance UIDs; inspect old item_id consumers before removing adapters. |
| Character/LocalPlayer/physics/hitboxes/weapons/maps | Replace through small 3D vertical slices, preserving session/replication interfaces. |
| RewardService/loot | Separate XP, contribution, item rolls and GroundLoot/Pickup. |
| Party/guild/trade/shops/quests/dungeon/events | Quarantine outside the spike path; Open-MT2 equivalents do not justify enabling them. |
| Metin packets, Node/MySQL/Redis, Open-MT2 data/assets | Do not add to runtime; implement our own Godot rules. |

Removal/test status: [repository-cleanup.md](repository-cleanup.md). The analysis
does not automatically delete more modules or change existing saves.

## Recommended implementation order at analysis time

1. Minimal 3D world/two sessions: Spike, CharacterBody3D, camera, server movement,
   replication/reconnect; verify two actual clients entering.
2. Item vertical path: ItemDefinition/ItemInstance, UID, new equip, inventory
   snapshot and persistence. Same-definition swords retain distinct bonuses/
   identity after equip/relogin.
3. One PvE mob: AttackRequest, validation, HP, idle/chase/attack/return, death and
   one-time reward.
4. Ground loot: drop table, 3D entity, rights, distance, full bag and two competing pickups.
5. Upgrade +1/reroll: costs, server result, same-instance mutation, atomic save and
   retry idempotency; full +0...+9 follows validation.

This historical recommendation follows the spike plan; analysis alone does not
mean any stage had been implemented.

## Verification scenarios to reuse

Selected source tests were read as edge-case examples: [PickupItemService.test](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/test/unit/game/app/service/PickupItemService.test.ts), [PlayerAttackThrottle.test](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/test/unit/core/domain/entities/game/player/PlayerAttackThrottle.test.ts), [ItemManagerFlush.test](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/test/unit/core/domain/manager/ItemManagerFlush.test.ts).
They were not executed during this analysis.

Our criteria: reject attacks out of range/in another instance; spam cannot increase
legal actions; one pickup per item; full bag does not delete loot; foreign UIDs
cannot be equipped; same-definition instances keep their bonuses; relog retains
equip/upgrade/affixes; upgrade/reroll save failures do not consume costs without
item mutation; retry does not charge/grant twice.

## Material provenance

Reference sources were kept locally in ignored `.godot/reference/open-mt2`, not
as fork code. Only this analysis was added; no Open-MT2 implementation/assets copied.

[LICENSE](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/LICENSE) contains GPL v3 and README indicates GPL, while [package.json](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/package.json) declares
license ISC. This is source metadata inconsistency, not a legal determination.
Current use is rule reference plus our own implementation.
