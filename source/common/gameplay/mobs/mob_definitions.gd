class_name MobDefinitions
extends RefCounted
## Shared content registry. Runtime snapshots carry only the stable key.
const WILD_DOG: MobDefinition = preload("res://source/common/gameplay/mobs/wild_dog.tres")
const FERAL_DOG: MobDefinition = preload("res://source/common/gameplay/mobs/feral_dog.tres")
const HOLLOW_HOUND: MobDefinition = preload("res://source/common/gameplay/mobs/hollow_hound.tres")
const METIN_HOUND_ELITE: MobDefinition = preload("res://source/common/gameplay/mobs/metin_hound_elite.tres")

static func resolve(key: StringName) -> MobDefinition:
	match key:
		&"wild_dog": return WILD_DOG
		&"feral_dog": return FERAL_DOG
		&"hollow_hound": return HOLLOW_HOUND
		&"metin_hound_elite": return METIN_HOUND_ELITE
	return null
