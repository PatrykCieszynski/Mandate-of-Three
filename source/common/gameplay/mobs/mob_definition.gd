class_name MobDefinition
extends Resource
## Stable content identity; runtime instance IDs are allocated by the World.
@export var reaction_profile: HitReactionProfile = preload("res://source/common/gameplay/combat/normal_reactions.tres")
@export var mob_key: StringName
@export var display_name: String
@export var max_hp: int = 100
@export var attack_damage: int = 5
@export var move_speed: float = 2.8
@export var proximity_aggro: bool = true
@export var visual_id: StringName = &"stray_dog"
@export var movement_body_radius: float = 0.6
@export var movement_body_height: float = 1.2
@export var aggro_radius: float = 6.0
@export var attack_reach: float = 1.65
@export var attack_interval: float = 1.2
@export var experience_reward: int = 20
@export var basic_attack: AttackHitDefinition = preload("res://source/common/gameplay/combat/mob_melee.tres")
func valid() -> bool:
	return is_finite(aggro_radius) and aggro_radius >= 0 and is_finite(attack_reach) and attack_reach > 0 and is_finite(attack_interval) and attack_interval > 0 and experience_reward >= 0 and basic_attack != null and reaction_profile != null and not mob_key.is_empty() and not display_name.strip_edges().is_empty() and max_hp > 0 and attack_damage >= 0 and is_finite(move_speed) and move_speed > 0 and not visual_id.is_empty() and is_finite(movement_body_radius) and movement_body_radius > 0 and is_finite(movement_body_height) and movement_body_height >= movement_body_radius*2
