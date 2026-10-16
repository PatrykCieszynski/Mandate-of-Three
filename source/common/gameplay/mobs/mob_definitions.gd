class_name MobDefinitions
extends RefCounted
## Shared content registry. Runtime snapshots carry only the stable key.
const WILD_DOG: MobDefinition = preload("res://source/common/gameplay/mobs/wild_dog.tres")
const FERAL_DOG: MobDefinition = preload("res://source/common/gameplay/mobs/feral_dog.tres")
const HOLLOW_HOUND: MobDefinition = preload("res://source/common/gameplay/mobs/hollow_hound.tres")
const METIN_HOUND_ELITE: MobDefinition = preload("res://source/common/gameplay/mobs/metin_hound_elite.tres")

const FOREST_WOLF: MobDefinition = preload("res://source/common/gameplay/mobs/forest_wolf.tres")
const DIRE_WOLF: MobDefinition = preload("res://source/common/gameplay/mobs/dire_wolf.tres")
const WOLF_ALPHA: MobDefinition = preload("res://source/common/gameplay/mobs/wolf_alpha.tres")
const ROAD_BANDIT: MobDefinition = preload("res://source/common/gameplay/mobs/road_bandit.tres")
const BANDIT_RAIDER: MobDefinition = preload("res://source/common/gameplay/mobs/bandit_raider.tres")
const BANDIT_CAPTAIN_3D: MobDefinition = preload("res://source/common/gameplay/mobs/bandit_captain_3d.tres")

static func resolve(key: StringName) -> MobDefinition:
	match key:
		&"wild_dog": return WILD_DOG
		&"feral_dog": return FERAL_DOG
		&"hollow_hound": return HOLLOW_HOUND
		&"metin_hound_elite": return METIN_HOUND_ELITE
		&"forest_wolf": return FOREST_WOLF
		&"dire_wolf": return DIRE_WOLF
		&"wolf_alpha": return WOLF_ALPHA
		&"road_bandit": return ROAD_BANDIT
		&"bandit_raider": return BANDIT_RAIDER
		&"bandit_captain_3d": return BANDIT_CAPTAIN_3D
	return null

static func is_registered(definition: MobDefinition) -> bool:
	return definition != null and resolve(definition.mob_key) == definition
