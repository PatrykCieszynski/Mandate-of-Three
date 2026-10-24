extends Node
## Events Autoload (only for the client side)
## Should be removed on non-client exports.


## Dimension-neutral readiness; new 3D gameplay does not instantiate LocalPlayer2D.
signal world_ready(player: Node)
signal player_profile_requested(id: int)
## Same as player_profile_requested but the target is identified by PEER id (a world
## click) — the client doesn't carry the persistent player_id, so the server resolves
## it (see profile.get.gd).
signal player_profile_by_peer_requested(peer_id: int)
signal open_menu_requested(menu: StringName, arg: Variant)
signal dm_requested(id: int)
## Emitted whenever the active input type changes. [br]
## [b]Example[/b]: switching from keyboard to gamepad.
signal input_changed(input_type: InputComponent.InputType)

var chat_history = preload("res://source/client/ui_web/chat_history.gd").new()
var player_id: int
## Fires when the wardstone mirror updates (login sync or a fresh grant) —
## sealed portals listen so they unseal live, without a map reload.
signal wardstones_changed
## Earned wardstone slugs, mirrored from the server (wardstones.set push at login
## + on every grant) — lets sealed portals render/explain with no round trip.
var wardstones: PackedStringArray
## The local character's level, mirrored from progression data (progression.get on
## spawn/map change + combat.reward pushes — see HUD._apply_progression). Client-side
## cosmetic checks only; gameplay admission remains server-authoritative.
var player_level: int = 1
## True while a blocking menu is open (NPC dialogue, shop, quest log, inventory).
## While set, the local player's movement and actions are suppressed, so you can't
## walk or fight with a menu up, and can't keep one open to act from afar. Only the
## movement polling is gated. Raw key events still flow, so menu UI can use arrows
## or stick for navigation later.
var menu_open: bool = false
## How many talkable world interactables (NPC click-areas) the cursor is over. While
## > 0, combat input is suppressed (InputComponent._ui_blocks_combat) so clicking an NPC
## to talk doesn't ALSO fire your weapon — the world-space mirror of the GUI gate.
## Counter, so overlapping NPCs balance; each NPC clears its own contribution on free.
var world_interactables_hovered: int = 0
var stats: DataDict = DataDict.new()
var settings: Settings = Settings.new()
var quick_slots: DataDict = DataDict.new()

## Set of player_ids the local user has blocked. Used by chat_menu to drop
## incoming messages from blocked senders (server already filters too, but
## this catches the brief window between a Block click and the next message
## the server may have already dispatched). Hydrated once at instance entry
## via social.block.list and kept in sync as the user blocks/unblocks.
var blocked_ids: Dictionary[int, bool]
## Fired when blocked_ids changes — profile/chat-settings menus listen so
## their UI mirrors the live state without a refresh round-trip.
signal blocked_ids_changed

var language: String:
	set(value):
		var loaded_locales: PackedStringArray = TranslationServer.get_loaded_locales()
		if loaded_locales.is_empty() or value not in loaded_locales: value = "en_US"
		language = value
		TranslationServer.set_locale(value)

var input_type: InputComponent.InputType:
	set(value):
		input_type = value
		input_changed.emit(value)


func _ready() -> void:
	if not GameMode.is_client():
		queue_free()
	Client.subscribe(&"player_id.set", func(payload: Dictionary):
		player_id = payload.get("player_id", 0))
	Client.subscribe(&"wardstones.set", func(payload: Dictionary):
		wardstones = PackedStringArray(payload.get("wardstones", []))
		wardstones_changed.emit())
	Client.subscribe(&"stats.get", func(data: Dictionary):
		stats.data.merge(data, true)
	)
	Client.subscribe(&"combat.reward", _on_combat_reward)

	settings.load_file()
	settings.setting_changed.connect(_on_setting_changed)
	language = settings.data.get(&"general", {}).get(&"language", "en_US")
	# Saved keybinds must hold from boot (gateway, menus) — not only once the
	# local player's InputComponent spawns.
	InputComponent.apply_saved_binds()


## Server-pushed kill rewards: surface them as ONE grouped toast card
## ("Defeated a Goblin" + XP + loot + level-up) so the player reads it
## as a single event instead of three flashes that happen to land
## together. enemy_type may be missing for non-mob reward paths (basing
## etc.) — falls back to a generic "Reward" header in that case.
func _on_combat_reward(data: Dictionary) -> void:
	var enemy_type: String = str(data.get("enemy_type", ""))
	var title: String = "Defeated %s" % _readable_enemy_name(enemy_type) if not enemy_type.is_empty() else "Reward"

	# Loot goes to the compact ICON feed (self-coalescing pills — see LootFeed),
	# and +XP now reads on the XP BAR itself (hud floaty + pulse) — both moved
	# off the kill card (docs/notifications.md toast-lane rework), so the card
	# is just the "Defeated X ×N" headline.
	var lines: PackedStringArray = PackedStringArray()
	for entry: Dictionary in data.get("loot", []):
		LootFeed.add_item(int(entry.get("id", 0)), int(entry.get("amount", 1)), str(entry.get("name", "item")))
	# Character level-up = the ceremony lane: a center-screen banner (the in-world
	# flare + camera kick ride the level.up broadcast, not this push). Mastery
	# stays a corner card — frequent enough that a banner would wear thin.
	if int(data.get("levels_gained", 0)) > 0:
		Announcer.announce(
			"Level %d" % int(data.get("level", 1)),
			"+%d attribute points" % int(data.get("points_gained", 0)),
			{"sfx": UISound.LEVELUP}
		)
	if lines.is_empty() and enemy_type.is_empty():
		return  # Nothing to show.
	# Repeated kills coalesce into one "Defeated a Goblin ×N" card; quest/basing
	# reward turn-ins (no enemy_type) are rare one-offs on the big lane.
	if enemy_type.is_empty():
		Toaster.toast_group(title, lines)
	else:
		Toaster.toast_feed("kill:" + enemy_type, title, lines)


## Readable enemy name for reward notifications.
func _readable_enemy_name(slug: String) -> String:
	if slug.is_empty():
		return "an enemy"
	var words: PackedStringArray = slug.split("_")
	var titled: PackedStringArray = PackedStringArray()
	for w: String in words:
		if w.is_empty():
			continue
		titled.append(w.substr(0, 1).to_upper() + w.substr(1))
	var pretty: String = " ".join(titled)
	var article: String = "an" if "aeiou".contains(pretty.substr(0, 1).to_lower()) else "a"
	return "%s %s" % [article, pretty]


## Replace the client block list after server bootstrap.
func set_blocked_ids(entries: Array) -> void:
	blocked_ids.clear()
	for entry: Dictionary in entries:
		blocked_ids[int(entry.get("id", 0))] = true
	blocked_ids_changed.emit()


## Mark a player as blocked locally. Server confirms first.
func add_blocked(id: int) -> void:
	if id <= 0:
		return
	blocked_ids[id] = true
	blocked_ids_changed.emit()


## Unmark a player. Server confirms first.
func remove_blocked(id: int) -> void:
	blocked_ids.erase(id)
	blocked_ids_changed.emit()


func _on_setting_changed(section: StringName, property: StringName, new_value: Variant) -> void:
	match property:
		"language":
			language = new_value


class DataDict:
	signal data_changed(property: Variant, value: Variant)
	
	var data: Dictionary
	
	
	func _set(property: StringName, value: Variant) -> bool:
		if property == &"data":
			return false
		data[property] = value
		data_changed.emit(property, value)
		return true
	
	
	func set_key(key: Variant, value: Variant) -> void:
		data.set(key, value)
		data_changed.emit(key, value)
	
	
	func get_key(property: Variant, default: Variant = null) -> Variant:
		return data.get(property, default)


class Settings:
	const SETTINGS_PATH: String = "user://client_settings.cfg"
	const DEFAULTS_PATH: String = "res://data/config/client_default_settings.cfg"

	signal setting_changed(section: StringName, property: StringName, new_value: Variant)

	var data: Dictionary
	var _defaults: Dictionary


	func load_file() -> void:
		_defaults = ConfigFileUtils.load_file_with_defaults(DEFAULTS_PATH, {})
		data = ConfigFileUtils.load_file_with_defaults(SETTINGS_PATH, _defaults)


	## The shipped default for a setting ([code]null[/code] if it has none) —
	## used by "Reset to Defaults" flows.
	func get_default(section: StringName, property: StringName) -> Variant:
		return _defaults.get(section, {}).get(property)


	## Every shipped default of a section (empty if the section has none).
	func get_defaults_section(section: StringName) -> Dictionary:
		return _defaults.get(section, {})


	func save() -> void:
		ConfigFileUtils.save_sections(data, SETTINGS_PATH)
	

	func get_value(section: StringName, property: StringName) -> Variant:
		return data.get(section, {}).get(property)


	func set_value(section: StringName, property: StringName, value: Variant) -> void:
		if not data.has(section):
			data[section] = {}
		data[section][property] = value
		setting_changed.emit(section, property, value)
		save()
