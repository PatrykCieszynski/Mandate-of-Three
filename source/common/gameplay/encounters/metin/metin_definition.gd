class_name MetinDefinition
extends Resource
@export var definition_id: StringName = &"first_metin"
@export var display_name: String = "Metin Stone"
@export var max_hp: int = 800
@export var respawn_seconds: float = 90.0
@export var wave_lifetime_seconds: float = 180.0
@export var reward_yang: int = 300
@export var waves: Array[MetinWaveDefinition] = []
func valid() -> bool:
	if max_hp <= 0 or respawn_seconds <= 0 or wave_lifetime_seconds <= 0 or reward_yang <= 0 or waves.is_empty(): return false
	var previous: int = 100
	for wave: MetinWaveDefinition in waves:
		if wave == null or not wave.valid() or wave.hp_percent >= previous: return false
		previous = wave.hp_percent
	return true
