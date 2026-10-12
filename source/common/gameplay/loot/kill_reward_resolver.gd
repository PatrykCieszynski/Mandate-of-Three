class_name KillRewardResolver
extends RefCounted
## Only kill rewards: contribution winner and the current prototype drop policy.
var _services: MandateWorldServices
var _ground: GroundLootSystem
var _currency: CurrencyEndpoint3D

func setup(services: MandateWorldServices, ground: GroundLootSystem, currency: CurrencyEndpoint3D) -> void:
	_services = services
	_ground = ground
	_currency = currency



func handle_mob_death(result: MobDeathResult) -> void:
	spawn_reward(result.position,result.reward_owner,result.timestamp_ms)
	var player := _services.current_player(result.reward_owner,result.recipient)
	if result.reward_owner>0 and player!=null and _services.progression()!=null:
		_services.progression().award_experience(player,result.experience_reward)

func spawn_reward(position: Vector3, owner_id: int, now: int, yang: int = CurrencyEndpoint3D.DOG_YANG) -> void:
	var owner_name := _ground.owner_name_for_owner(owner_id)
	_ground.spawn_item(position,owner_id,owner_name,now,ItemDefinitions.IRON_SWORD.definition_id,randi_range(1,9))
	_currency.spawn_currency(position,owner_id,owner_name,now,yang)
