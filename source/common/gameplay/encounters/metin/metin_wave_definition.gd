class_name MetinWaveDefinition
extends Resource
@export_range(1,99) var hp_percent: int = 75
@export var members: Array[MobSpawnEntry] = []
@export var spawn_radius: float = 4.0
func valid() -> bool:
	if hp_percent < 1 or hp_percent > 99 or not is_finite(spawn_radius) or spawn_radius < 2 or members.is_empty(): return false
	for member: MobSpawnEntry in members:
		if member == null or not member.valid(): return false
	return true
