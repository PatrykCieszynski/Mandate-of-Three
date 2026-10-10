class_name MobDefinition
extends Resource
## Stable content identity; runtime instance IDs are allocated by the World.
@export var mob_key: StringName
@export var display_name: String
@export var max_hp: int = 100
@export var attack_damage: int = 5
@export var move_speed: float = 2.8
@export var visual_id: StringName = &"stray_dog"
func valid() -> bool:
	return not mob_key.is_empty() and not display_name.strip_edges().is_empty() and max_hp > 0 and attack_damage >= 0 and is_finite(move_speed) and move_speed > 0 and not visual_id.is_empty()
