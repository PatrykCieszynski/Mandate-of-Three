class_name KillRewardResolver
extends RefCounted
## Only kill rewards: contribution winner and the current prototype drop policy.
var _services: MandateWorldServices
var _ground: GroundLootSystem
var _currency: SpikeCurrency3D

func setup(services: MandateWorldServices, ground: GroundLootSystem, currency: SpikeCurrency3D) -> void:
	_services = services
	_ground = ground
	_currency = currency

static func owner_for_contributions(contributions: Dictionary) -> int:
	var owner_id := 0
	var highest := -1
	for contributor: int in contributions:
		if contributions[contributor]>highest or (contributions[contributor]==highest and contributor<owner_id):
			owner_id = contributor
			highest = contributions[contributor]
	return owner_id

func handle_mob_death(mob: SpikeWildDog3D, now: int) -> void:
	var owner_id := owner_for_contributions(mob.contributions)
	spawn_reward(mob.position,owner_id,now)
	var player := _services.current_player(owner_id,mob.contribution_players.get(owner_id))
	if owner_id>0 and player!=null and _services.progression()!=null: _services.progression().award_experience(player,mob.definition.experience_reward)

func spawn_reward(position: Vector3, owner_id: int, now: int, yang: int = SpikeCurrency3D.DOG_YANG) -> void:
	var owner_name := _ground.owner_name_for_owner(owner_id)
	_ground.spawn_item(position,owner_id,owner_name,now,ItemDefinitions.IRON_SWORD.definition_id,randi_range(1,9))
	_currency.spawn_currency(position,owner_id,owner_name,now,yang)
