class_name LootContent
extends RefCounted
## Explicit content sources. Each table contributes entries, not an automatic roll.
const GLOBAL: LootTable = preload("res://source/common/gameplay/loot/tables/global_upgrade_ore.tres")
const FIRST_REGION: LootTable = preload("res://source/common/gameplay/loot/tables/first_region_resin.tres")
const BEAST: LootTable = preload("res://source/common/gameplay/loot/tables/beast_hides.tres")
const HUMANOID: LootTable = preload("res://source/common/gameplay/loot/tables/humanoid_tokens.tres")
const WILD_DOG: LootTable = preload("res://source/common/gameplay/loot/tables/wild_dog_sword.tres")
const FOREST_WOLF: LootTable = preload("res://source/common/gameplay/loot/tables/forest_wolf_fangs.tres")
const ROAD_BANDIT: LootTable = preload("res://source/common/gameplay/loot/tables/road_bandit_sword.tres")

static func tables_for(region_key: StringName, category: StringName, mob_key: StringName) -> Array[LootTable]:
	var result: Array[LootTable] = [GLOBAL]
	if region_key == &"first_region":
		result.append(FIRST_REGION)
	match category:
		&"beast": result.append(BEAST)
		&"humanoid": result.append(HUMANOID)
	match mob_key:
		&"wild_dog": result.append(WILD_DOG)
		&"forest_wolf": result.append(FOREST_WOLF)
		&"road_bandit": result.append(ROAD_BANDIT)
	return result
