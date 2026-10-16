class_name MobDefinition
extends Resource
## Stable content identity; runtime instance IDs are allocated by the World.
@export var reaction_profile: HitReactionProfile = preload("res://source/common/gameplay/combat/normal_reactions.tres")
@export var mob_key: StringName
@export var display_name: String
const CATEGORIES: Array[StringName] = [&"beast", &"humanoid", &"undead", &"demon", &"construct"]
const RANKS: Array[StringName] = [&"normal", &"strong", &"elite", &"boss"]
@export var category: StringName = &"beast"
@export var family: StringName = &"dogs"
@export var rank: StringName = &"normal"
## Only the number of attempts is sampled at spawn; items are resolved on death.
@export_range(1, 4, 1) var min_loot_rolls: int = 1
@export_range(1, 4, 1) var max_loot_rolls: int = 3

func sample_spawn_loot_rolls(rng: RandomNumberGenerator) -> int:
	assert(valid() and rng != null)
	return rng.randi_range(min_loot_rolls, max_loot_rolls)

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
	return CATEGORIES.has(category) and RANKS.has(rank) and not family.is_empty() and min_loot_rolls >= 1 and min_loot_rolls <= max_loot_rolls and max_loot_rolls <= 4 and is_finite(aggro_radius) and aggro_radius >= 0 and is_finite(attack_reach) and attack_reach > 0 and is_finite(attack_interval) and attack_interval > 0 and experience_reward >= 0 and basic_attack != null and reaction_profile != null and not mob_key.is_empty() and not display_name.strip_edges().is_empty() and max_hp > 0 and attack_damage >= 0 and is_finite(move_speed) and move_speed > 0 and not visual_id.is_empty() and is_finite(movement_body_radius) and movement_body_radius > 0 and is_finite(movement_body_height) and movement_body_height >= movement_body_radius*2
