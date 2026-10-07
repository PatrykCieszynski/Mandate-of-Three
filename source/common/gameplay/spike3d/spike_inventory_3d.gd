class_name SpikeInventory3D
extends Node
## UID commands and private inventory snapshots share the authenticated map path.

signal state_changed(state: Dictionary)
var state: Dictionary = {}
var public_weapons: Dictionary[int, String] = {}
var _last_action_ms: Dictionary[int, int] = {}
var _world: Node
var _panel: PanelContainer
var _summary: Label
var _message: Label
var _rows: VBoxContainer
var _pending: bool = false
var _new_item_uid: String = ""
var _pickup_notice: String = ""

func _ready() -> void:
	_world = get_parent()
	if GameMode.is_client():
		_build_panel()

func _store() -> ItemStoreSqlite:
	if WorldServer.curr == null or WorldServer.curr.database == null:
		return null
	return WorldServer.curr.database.item_store

func initialize_peer(peer_id: int) -> void:
	var store: ItemStoreSqlite = _store()
	if store == null:
		return # Physics-only fixture has no database or item domain.
	var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	var result: Dictionary = store.initialize_character(resource.player_id)
	_send_state(peer_id, "" if result.ok else str(result.error))
	for other_id: int in public_weapons:
		receive_weapon.rpc_id(peer_id, other_id, public_weapons[other_id])

func remove_peer(peer_id: int) -> void:
	public_weapons.erase(peer_id)
	_last_action_ms.erase(peer_id)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_equipment(action: String, uid: String, revision: int) -> void:
	if not GameMode.is_world_server():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer_id) or _store() == null:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_action_ms.get(peer_id, -1000) < 100:
		_send_state(peer_id, "too_fast")
		return
	_last_action_ms[peer_id] = now
	var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	var result: Dictionary = _store().change_equipment(resource.player_id, uid, revision, action)
	_send_state(peer_id, "" if result.ok else str(result.error))

func _send_state(peer_id: int, error: String = "") -> void:
	var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	if resource == null:
		return
	var snapshot: Dictionary = _store().inventory(resource.player_id)
	WorldServer.curr.update_runtime_equipment(resource.player_id, snapshot)
	if error != "":
		snapshot["error"] = error
	receive_inventory.rpc_id(peer_id, snapshot)
	if not snapshot.ok:
		return
	var definition_id: String = ""
	var uid: String = str(snapshot.equipment.get("weapon", ""))
	for item: Dictionary in snapshot.items:
		if item.uid == uid:
			definition_id = str(item.definition_id)
	public_weapons[peer_id] = definition_id
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null:
		body.set_weapon(definition_id)
	for observer: int in _world.characters:
		receive_weapon.rpc_id(observer, peer_id, definition_id)

@rpc("authority", "call_remote", "reliable", 1)
func receive_inventory(snapshot: Dictionary) -> void:
	if GameMode.is_world_server():
		return
	if state.get("ok", false) and snapshot.get("ok", false):
		var known: Dictionary = {}
		for item: Dictionary in state.items: known[str(item.uid)] = true
		for item: Dictionary in snapshot.items:
			if not known.has(str(item.uid)):
				_new_item_uid = str(item.uid)
				_pickup_notice = "Podniesiono: %s · atak broni %d. Wybierz Załóż, aby zmienić broń." % [item.item_name, int(item.stats.get("attack", 0))]
	state = snapshot.duplicate(true)
	_pending = false
	_render_items()
	state_changed.emit(state)

@rpc("authority", "call_remote", "reliable", 0)
func receive_weapon(peer_id: int, definition_id: String) -> void:
	if GameMode.is_world_server():
		return
	public_weapons[peer_id] = definition_id
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null:
		body.set_weapon(definition_id)

func _build_panel() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 5
	add_child(canvas)
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -390
	_panel.offset_right = -20
	_panel.offset_top = 20
	_panel.offset_bottom = 510
	canvas.add_child(_panel)
	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	_panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)
	var title := Label.new()
	title.text = "Ekwipunek"
	title.add_theme_font_size_override("font_size", 24)
	content.add_child(title)
	_summary = Label.new()
	_summary.text = "Ładowanie ekwipunku…"
	content.add_child(_summary)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 280)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 14)
	scroll.add_child(_rows)
	_message = Label.new()
	_message.add_theme_font_size_override("font_size", 14)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_message)
	var close := Button.new()
	close.text = "Zamknij · I / Esc"
	close.pressed.connect(_toggle_panel.bind(false))
	content.add_child(close)
	_panel.hide()

func _unhandled_key_input(event: InputEvent) -> void:
	if _panel == null or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_I:
		_toggle_panel(not _panel.visible)
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE and _panel.visible:
		_toggle_panel(false)
		get_viewport().set_input_as_handled()

func _toggle_panel(open: bool) -> void:
	_panel.visible = open
	ClientState.menu_open = open

func _render_items() -> void:
	if _rows == null:
		return
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if not state.get("ok", false):
		_summary.text = "Nie udało się wczytać ekwipunku."
		_message.text = _error_message(str(state.get("error", "storage")))
		return
	var bag_count: int = 0
	for item: Dictionary in state.items:
		if item.location == "bag": bag_count += 1
	var weapon_name: String = "Brak broni"
	for item: Dictionary in state.items:
		if str(item.uid) == str(state.equipment.get("weapon", "")):
			weapon_name = str(item.item_name)
	_summary.text = "Atak postaci: %d · Torba: %d / 24\nBroń: %s" % [int(state.stats.get("attack", 10)), bag_count, weapon_name]
	var error: String = str(state.get("error", ""))
	_message.text = _error_message(error) if error != "" or _pickup_notice == "" else _pickup_notice
	var display_items: Array = state.items.duplicate()
	display_items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.location != b.location: return a.location == "equipment"
		if (str(a.uid) == _new_item_uid) != (str(b.uid) == _new_item_uid): return str(a.uid) == _new_item_uid
		if a.stats.get("attack", 0) != b.stats.get("attack", 0): return a.stats.get("attack", 0) > b.stats.get("attack", 0)
		return int(a.bag_position) < int(b.bag_position))
	for item: Dictionary in display_items:
		var card := VBoxContainer.new()
		card.name = "Item_" + str(item.uid)
		_rows.add_child(card)
		var title := Label.new()
		title.add_theme_font_size_override("font_size", 16)
		var equipped: bool = item.location == "equipment"
		title.text = "%s +%d%s%s" % [item.item_name, int(item.upgrade_level), " · założony" if equipped else "", " · nowy" if str(item.uid) == _new_item_uid else ""]
		title.tooltip_text = "Egzemplarz: " + str(item.uid)
		card.add_child(title)
		var description := Label.new()
		description.add_theme_font_size_override("font_size", 14)
		var bonus: float = 0
		for affix: Dictionary in item.affixes:
			if affix.stat == "attack": bonus += float(affix.value)
		description.text = "Atak broni: %d · bonus ataku +%d" % [int(item.stats.get("attack", 0)), int(bonus)]
		card.add_child(description)
		if not equipped:
			var comparison: Dictionary = weapon_comparison(item)
			var preview := Label.new()
			preview.name = "Comparison"
			preview.add_theme_font_size_override("font_size", 14)
			var difference: String = "bez zmiany" if comparison.delta == 0 else "%+d" % int(comparison.delta)
			preview.text = "Po założeniu: %d ataku (%s)" % [int(comparison.attack), difference]
			preview.modulate = Color("8ce5a3") if comparison.delta > 0 else (Color("f1a3a3") if comparison.delta < 0 else Color("cccccc"))
			card.add_child(preview)
		var button := Button.new()
		button.text = "Zdejmij" if equipped else "Załóż"
		button.disabled = _pending
		button.pressed.connect(_act.bind("unequip" if equipped else "equip", str(item.uid), int(item.revision)))
		card.add_child(button)

func weapon_comparison(item: Dictionary) -> Dictionary:
	# Presentation uses server-calculated instance stats. Equip and damage remain
	# authoritative; this preview never changes or sends stats back to the server.
	var current_attack: int = int(state.get("stats", {}).get("attack", 10))
	var previous_attack: int = 0
	var equipped_uid: String = str(state.get("equipment", {}).get("weapon", ""))
	for equipped: Dictionary in state.get("items", []):
		if str(equipped.uid) == equipped_uid:
			previous_attack = int(equipped.stats.get("attack", 0))
	var attack: int = current_attack - previous_attack + int(item.stats.get("attack", 0))
	return {"attack": attack, "delta": attack - current_attack}

func _act(action: String, uid: String, revision: int) -> void:
	if _pending:
		return
	_pending = true
	_render_items()
	request_equipment.rpc_id(1, action, uid, revision)

func _error_message(reason: String) -> String:
	match reason:
		"": return "Porównaj broń i wybierz egzemplarz do założenia."
		"stale": return "Stan przedmiotu się zmienił. Wybierz go ponownie."
		"owner": return "Ten przedmiot nie należy do tej postaci."
		"too_fast": return "Odczekaj chwilę przed kolejną zmianą."
		"bag_full": return "W torbie nie ma wolnego miejsca."
		_: return "Operacja nie została zapisana. Spróbuj ponownie."
