class_name MobDeathResult
extends RefCounted
## Closed death fact; no live mob or mutable MobDefinition reference.
var mob_id: int
var mob_key: StringName
var position: Vector3
var timestamp_ms: int
var party_claims: Dictionary = {}
var contributions: Dictionary
var reward_owner: int
var experience_reward: int
## Frozen snapshot of classification and the count drawn at World spawn.
var spawn_base_loot_rolls: int
var category: StringName
var family: StringName
var rank: StringName
# Recipient fallback belongs to player progression, never the mob runtime.
var recipient: PlayerResource

static func owner_for_contributions(contributions: Dictionary) -> int:
	var owner_id := 0
	var highest := -1
	for contributor: int in contributions:
		if contributions[contributor]>highest or (contributions[contributor]==highest and contributor<owner_id):
			owner_id = contributor
			highest = contributions[contributor]
	return owner_id

static func capture(mob: MobActor3D, now: int, services: MandateWorldServices) -> MobDeathResult:
	var result := MobDeathResult.new()
	result.mob_id = mob.mob_instance_id
	result.mob_key = mob.mob_key
	result.position = mob.position
	result.timestamp_ms = now
	result.contributions = mob.contributions.duplicate()
	result.party_claims = mob.reward_claims.duplicate(true)
	result.reward_owner = owner_for_contributions(result.contributions)
	result.experience_reward = mob.definition.experience_reward
	result.spawn_base_loot_rolls = mob.spawn_base_loot_rolls
	result.category = mob.definition.category
	result.family = mob.definition.family
	result.rank = mob.definition.rank
	result.recipient = services.current_player(result.reward_owner,mob.contribution_players.get(result.reward_owner))
	return result
