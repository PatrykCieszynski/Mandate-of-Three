extends Node
## Active rule contracts, scope selection and independent seeded rolls.
func rule(id: String, scope: String, chance: int = 10000) -> Dictionary:
	return {"event_id": id, "scope": scope, "chance_bp": chance,
		"definition_id": &"upgrade_ore", "amount": 2}

func _ready() -> void:
	var service := WorldEventDropService.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 123
	assert(service.resolve_drops(rng).is_empty())
	var rules := [rule("blaski", "all"), rule("season", "seasonal")]
	assert(service.set_active_rules(&"classic", rules))
	assert(service.active_drop_events.size() == 1)
	var classic := service.resolve_drops(rng)
	assert(classic.size() == 1 and classic[0].definition_id == &"upgrade_ore" and classic[0].amount == 2)
	assert(service.set_active_rules(&"seasonal", rules))
	assert(service.active_drop_events.size() == 2 and service.resolve_drops(rng).size() == 2)
	assert(service.set_active_rules(&"classic", []))
	assert(service.resolve_drops(rng).is_empty())
	assert(service.set_active_rules(&"classic", [rule("never", "all", 0)]))
	assert(service.resolve_drops(rng).is_empty())
	assert(not service.set_active_rules(&"classic", [rule("bad", "all", 10001)]))
	assert(service.active_drop_events.size() == 1)
	assert(not service.set_active_rules(&"classic", [rule("same", "all"), rule("same", "all")]))
	assert(service.active_drop_events.size() == 1)
	assert(not service.set_active_rules(&"unknown", rules))
	assert(service.active_drop_events.size() == 1)
	print("WORLD_EVENT_DROPS_OK: idle path, scopes, independent rolls and atomic validation")
	get_tree().quit()
