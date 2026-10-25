class_name KillRewardResolver
extends RefCounted
## Death -> authoritative table selection/rolls -> ground reward; pickup belongs elsewhere.
var _services: MandateWorldServices
var _ground: GroundLootSystem
var _currency: CurrencyEndpoint3D
var _region_key: StringName = &""
var _rng := RandomNumberGenerator.new()
var _affix_rng := RandomNumberGenerator.new()
var event_drops := WorldEventDropService.new()
var party_rewards = preload("res://source/common/gameplay/party/party_rewards.gd").new(self)

func setup(services: MandateWorldServices, ground: GroundLootSystem, currency: CurrencyEndpoint3D, region_key: StringName = &"") -> void:
	_services = services
	_ground = ground
	_currency = currency
	_region_key = region_key
	_rng.randomize()
	_affix_rng.randomize()

func resolve_ordinary(result: MobDeathResult, luck_bp: int) -> Dictionary:
	var outcome: Dictionary=LootResolver.resolve(LootContent.tables_for(_region_key,result.category,result.mob_key),result.spawn_base_loot_rolls,luck_bp,_rng)
	if not outcome.ok: return outcome
	var decorated: Dictionary=preload("res://source/common/gameplay/loot/natural_affix_loot.gd").resolve(outcome.items,_affix_rng)
	if not decorated.ok: return decorated
	outcome.items=decorated.items
	return outcome

func handle_mob_death(result: MobDeathResult) -> void:
	if party_rewards.handle_mob(result): return
	# Temporary legacy arena fixture: keep old one-sword behavior until its
	# equipment/pickup scripts are converted. Production region is data-driven.
	if _region_key.is_empty():
		spawn_reward(result.position, result.reward_owner, result.timestamp_ms)
	else:
		spawn_ordinary_rewards(result)
	spawn_event_rewards(result)
	var player := _services.current_player(result.reward_owner, result.recipient)
	if result.reward_owner > 0 and player != null and _services.progression() != null:
		_services.progression().award_experience(player, result.experience_reward)

func spawn_ordinary_rewards(result: MobDeathResult) -> void:
	var owner_name: String = _ground.owner_name_for_owner(result.reward_owner)
	var luck_bp: int = 0
	if result.reward_owner > 0:
		# Authoritative runtime gear stats only. Until Luck gear exists this is zero;
		# never accept a roll chance supplied by clients.
		luck_bp = clampi(int(_services.runtime_stats(result.reward_owner).get(&"loot_luck_bp", 0)), 0, LootResolver.BASIS_POINTS)
	var outcome: Dictionary = resolve_ordinary(result,luck_bp)
	if not outcome.ok:
		# Invalid authored content must fail closed, without a partial item grant.
		push_error("Invalid authored ordinary loot for mob %s: %s" % [result.mob_key, outcome.error])
	else:
		for item: Dictionary in outcome.items:
			var uid: String = _ground.spawn_resolved_item(result.position, result.reward_owner, owner_name,
				result.timestamp_ms, StringName(item.definition_id), int(item.amount), item.affixes)
			if uid.is_empty():
				push_error("Resolved loot rejected by ground custody for mob %s" % result.mob_key)
	# Yang and XP are separate from item attempts, Luck and equipment rarity.
	_currency.spawn_currency(result.position, result.reward_owner, owner_name, result.timestamp_ms, CurrencyEndpoint3D.DOG_YANG)

## Event drops are independent of ordinary rolls, Yang, XP and Luck.
func spawn_event_rewards(result: MobDeathResult) -> void:
	var outcomes: Array[Dictionary] = event_drops.resolve_drops()
	if outcomes.is_empty():
		return
	var owner_name := _ground.owner_name_for_owner(result.reward_owner)
	for item: Dictionary in outcomes:
		var uid := _ground.spawn_resolved_item(result.position, result.reward_owner, owner_name,
			result.timestamp_ms, item.definition_id, item.amount, item.affixes)
		if uid.is_empty():
			push_error("Event ground custody rejected item for mob %s" % result.mob_key)

## Guaranteed legacy encounter reward, intentionally separate from ordinary tables.
## Metin stone still grants exactly one prototype sword and the configured Yang.
func spawn_reward(position: Vector3, owner_id: int, now: int, yang: int = CurrencyEndpoint3D.DOG_YANG) -> void:
	var owner_name := _ground.owner_name_for_owner(owner_id)
	_ground.spawn_item(position, owner_id, owner_name, now, ItemDefinitions.IRON_SWORD.definition_id, randi_range(1, 9))
	_currency.spawn_currency(position, owner_id, owner_name, now, yang)
