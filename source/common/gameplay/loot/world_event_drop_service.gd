class_name WorldEventDropService
extends RefCounted
## Server-side timed event drop policy. Scheduling/persistence belongs to the coordinator.
## No SQL or date checks occur on the kill path when no events are active.
const MAX_EVENTS: int = 32
const MAX_REWARDS_PER_KILL: int = 8
var active_drop_events: Array[Dictionary] = []
var _scheduled: Array[Dictionary] = []
var _world_kind: StringName = &""
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_rng.randomize()

## Replace the authoritative schedule snapshot. Invalid snapshots never replace live data.
func configure(world_kind: StringName, schedules: Array, now_unix: int) -> bool:
	if world_kind not in [&"classic", &"seasonal"] or schedules.size() > MAX_EVENTS:
		return false
	var validated: Array[Dictionary] = []
	var seen: Dictionary[StringName, bool] = {}
	for candidate: Variant in schedules:
		if not candidate is Dictionary:
			return false
		var event: Dictionary = candidate
		if not event.has_all(["event_id", "scope", "starts_at", "ends_at", "chance_bp", "definition_id", "amount"]):
			return false
		var event_id := StringName(str(event.event_id))
		var scope := StringName(str(event.scope))
		var definition := ItemDefinitions.get_definition(StringName(str(event.definition_id)))
		if event_id.is_empty() or seen.has(event_id) or scope not in [&"classic", &"seasonal", &"all"]:
			return false
		if not event.starts_at is int or not event.ends_at is int or event.starts_at < 0 or event.ends_at <= event.starts_at:
			return false
		if not event.chance_bp is int or event.chance_bp < 0 or event.chance_bp > 10000:
			return false
		if definition == null or not event.amount is int or event.amount < 1 or event.amount > definition.stack_limit:
			return false
		seen[event_id] = true
		validated.append({"event_id": event_id, "scope": scope,
			"starts_at": event.starts_at, "ends_at": event.ends_at,
			"chance_bp": event.chance_bp, "definition_id": definition.definition_id, "amount": event.amount})
	_world_kind = world_kind
	_scheduled = validated
	refresh(now_unix)
	return true

## Called by the coordinator's low-frequency timer, never by each mob death.
func refresh(now_unix: int) -> void:
	active_drop_events.clear()
	for event: Dictionary in _scheduled:
		if event.scope != &"all" and event.scope != _world_kind:
			continue
		if now_unix >= event.starts_at and now_unix < event.ends_at:
			active_drop_events.append(event)

## One independent chance per active event. Ordinary loot/Luck are unaffected.
func resolve_drops(rng: RandomNumberGenerator = null) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if active_drop_events.is_empty():
		return result
	var source: RandomNumberGenerator = rng if rng != null else _rng
	for event: Dictionary in active_drop_events:
		if result.size() >= MAX_REWARDS_PER_KILL:
			break
		if source.randi_range(0, 9999) < int(event.chance_bp):
			result.append({"definition_id": event.definition_id, "amount": event.amount, "affixes": []})
	return result
