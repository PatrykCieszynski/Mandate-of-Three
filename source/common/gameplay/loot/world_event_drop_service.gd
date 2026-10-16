class_name WorldEventDropService
extends RefCounted
## Active event drop rules supplied by a future authoritative event coordinator.
## No schedule, persistence, or world clock belongs to this service.
const MAX_EVENTS: int = 32
const MAX_REWARDS_PER_KILL: int = 8
var active_drop_events: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_rng.randomize()

## Atomically replace active rules for a known logical world.
## The coordinator handles time windows and broadcasts updates to world instances.
func set_active_rules(world_kind: StringName, rules: Array) -> bool:
	if world_kind not in [&"classic", &"seasonal"] or rules.size() > MAX_EVENTS:
		return false
	var validated: Array[Dictionary] = []
	var seen: Dictionary[StringName, bool] = {}
	for candidate: Variant in rules:
		if not candidate is Dictionary:
			return false
		var rule: Dictionary = candidate
		if not rule.has_all(["event_id", "scope", "chance_bp", "definition_id", "amount"]):
			return false
		var event_id := StringName(str(rule.event_id))
		var scope := StringName(str(rule.scope))
		var definition := ItemDefinitions.get_definition(StringName(str(rule.definition_id)))
		if event_id.is_empty() or seen.has(event_id) or scope not in [&"classic", &"seasonal", &"all"]:
			return false
		if not rule.chance_bp is int or rule.chance_bp < 0 or rule.chance_bp > 10000:
			return false
		if definition == null or not rule.amount is int or rule.amount < 1 or rule.amount > definition.stack_limit:
			return false
		seen[event_id] = true
		if scope == &"all" or scope == world_kind:
			validated.append({"event_id": event_id, "chance_bp": rule.chance_bp,
				"definition_id": definition.definition_id, "amount": rule.amount})
	active_drop_events = validated
	return true

## Independent roll per active rule; ordinary loot and Luck are not affected.
func resolve_drops(rng: RandomNumberGenerator = null) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if active_drop_events.is_empty():
		return result
	var source: RandomNumberGenerator = rng if rng != null else _rng
	for rule: Dictionary in active_drop_events:
		if result.size() >= MAX_REWARDS_PER_KILL:
			break
		if source.randi_range(0, 9999) < int(rule.chance_bp):
			result.append({"definition_id": rule.definition_id, "amount": rule.amount, "affixes": []})
	return result
