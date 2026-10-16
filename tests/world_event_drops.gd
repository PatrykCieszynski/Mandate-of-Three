extends Node
## Deterministic event scope/window and independent reward contracts.
func schedule(event_id: String, scope: String, start: int, end: int, chance: int = 10000) -> Dictionary:
	return {"event_id": event_id, "scope": scope, "starts_at": start, "ends_at": end,
		"chance_bp": chance, "definition_id": &"upgrade_ore", "amount": 2}

func _ready() -> void:
	var service := WorldEventDropService.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 123
	assert(service.resolve_drops(rng).is_empty())
	var events := [schedule("blaski", "all", 100, 7300), schedule("season", "seasonal", 100, 7300)]
	assert(service.configure(&"classic", events, 99))
	assert(service.active_drop_events.is_empty())
	service.refresh(100)
	assert(service.active_drop_events.size() == 1)
	var classic := service.resolve_drops(rng)
	assert(classic.size() == 1 and classic[0].definition_id == &"upgrade_ore" and classic[0].amount == 2)
	assert(service.configure(&"seasonal", events, 100))
	assert(service.active_drop_events.size() == 2 and service.resolve_drops(rng).size() == 2)
	service.refresh(7300)
	assert(service.resolve_drops(rng).is_empty())
	assert(service.configure(&"classic", [schedule("never", "all", 0, 10, 0)], 5))
	assert(service.resolve_drops(rng).is_empty())
	var invalid := schedule("bad", "all", 0, 10, 10001)
	assert(not service.configure(&"classic", [invalid], 5))
	assert(service.active_drop_events.size() == 1)
	assert(not service.configure(&"classic", [schedule("same", "all", 0, 10), schedule("same", "all", 0, 10)], 5))
	assert(service.active_drop_events.size() == 1)
	print("WORLD_EVENT_DROPS_OK: scopes, timing, independent rolls and fail-closed admission")
	get_tree().quit()
