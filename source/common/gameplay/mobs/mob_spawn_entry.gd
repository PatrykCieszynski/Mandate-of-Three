class_name MobSpawnEntry
extends Resource
@export var mob: MobDefinition
@export_range(1,100) var count: int = 1
func valid() -> bool:
	return mob != null and mob.valid() and count >= 1 and count <= 100
