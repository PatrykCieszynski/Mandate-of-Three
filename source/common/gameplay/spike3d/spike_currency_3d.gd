class_name SpikeCurrency3D
extends Node
## Ground currency is transient; only character wallet deltas reach SQLite.
const DOG_YANG: int = 30
const AUTO_REACH: float = 1.25
const PICKUP_REACH: float = 2.5
const TEST_SPEND_COST: int = 50
signal feedback_received(result: Dictionary)
signal state_changed(snapshot: Dictionary)
var ground: Dictionary[int, Dictionary] = {}
var state: Dictionary = {}
var _next_drop_id: int = 0
var _tick_elapsed: float = 0.0
var _spend_sequences: Dictionary[int, int] = {}
var _spend_ms: Dictionary[int, int] = {}
var _pickup_ms: Dictionary[int, int] = {}
var _world: SpikeWorld3D
var _visuals: Dictionary[int, Node3D] = {}
var _balance_label: Label
var _notice_label: Label
var _client_sequence: int = 0
var _notice: String = ""

func _ready() -> void:
	_world = get_parent()
	if GameMode.is_client(): _build_hud()

func _database() -> WorldDatabase:
	return null if WorldServer.curr == null else WorldServer.curr.database

func initialize_peer(peer_id: int) -> void:
	if _database() == null: return # Physics-only fixture.
	if not _database().load_wallet(_owner(peer_id)):
		push_error("Could not load Yang wallet; currency actions disabled for this character.")
	_send_snapshot()

func remove_peer(peer_id: int) -> void:
	_spend_sequences.erase(peer_id)
	_spend_ms.erase(peer_id)
	_pickup_ms.erase(peer_id)

func _owner(peer_id: int) -> int:
	var player: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	return 0 if player == null else player.player_id

func spawn_currency(position: Vector3, owner_id: int, owner_name: String, now: int) -> int:
	_next_drop_id += 1 # Local entity ID, never persisted and never an ItemInstance UID.
	ground[_next_drop_id] = {"amount": DOG_YANG, "position": position,
		"owner": owner_id, "owner_name": owner_name,
		"protected_until": now + SpikeCombat3D.PROTECTION_MS, "expires": now + SpikeCombat3D.LOOT_LIFETIME_MS}
	return _next_drop_id

func pickup_for_peer(peer_id: int, drop_id: int, now: int, reach: float = PICKUP_REACH) -> Dictionary:
	if not _world.combat_endpoint._living(peer_id) or _database() == null:
		return {"ok": false, "error": "player"}
	if not ground.has(drop_id): return {"ok": false, "error": "gone"}
	var drop: Dictionary = ground[drop_id]
	if now >= int(drop.expires):
		ground.erase(drop_id)
		return {"ok": false, "error": "gone"}
	var owner_id: int = _owner(peer_id)
	if now < int(drop.protected_until) and owner_id != int(drop.owner):
		return {"ok": false, "error": "reserved"}
	var position: Vector3 = _world.characters[peer_id].position
	if position.distance_to(drop.position) > reach or not _world.combat_endpoint._visible_between(position, drop.position):
		return {"ok": false, "error": "distance"}
	if not _database().add_yang(owner_id, int(drop.amount)):
		return {"ok": false, "error": "wallet"}
	ground.erase(drop_id) # Synchronous RAM mutation and erase: no double pickup.
	return {"ok": true, "amount": int(drop.amount), "balance": _database().wallet_balance(owner_id)}

@rpc("any_peer", "call_remote", "reliable", 1)
func request_pickup(drop_id: int) -> void:
	if not GameMode.is_world_server() or not _world.combat_endpoint._living(multiplayer.get_remote_sender_id()): return
	var peer_id: int = multiplayer.get_remote_sender_id()
	var now: int = Time.get_ticks_msec()
	if now - _pickup_ms.get(peer_id, -1000) < 100: return
	_pickup_ms[peer_id] = now
	receive_feedback.rpc_id(peer_id, pickup_for_peer(peer_id, drop_id, now))
	_send_snapshot()

func spend_for_peer(peer_id: int, sequence: int, now: int) -> Dictionary:
	if not _world.combat_endpoint._living(peer_id) or _database() == null:
		return {"ok": false, "error": "player"}
	if sequence < 0 or sequence > 2147483647 or sequence <= _spend_sequences.get(peer_id, -1):
		return {"ok": false, "error": "replay"}
	_spend_sequences[peer_id] = sequence
	if now - _spend_ms.get(peer_id, -1000) < 100: return {"ok": false, "error": "too_fast"}
	_spend_ms[peer_id] = now
	var result: Dictionary = _database().spend_yang(_owner(peer_id), TEST_SPEND_COST)
	if result.ok: result["spent"] = TEST_SPEND_COST
	return result

@rpc("any_peer", "call_remote", "reliable", 1)
func request_test_spend(sequence: int) -> void:
	if not GameMode.is_world_server(): return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer_id): return
	receive_feedback.rpc_id(peer_id, spend_for_peer(peer_id, sequence, Time.get_ticks_msec()))
	_send_snapshot()

func _physics_process(delta: float) -> void:
	if not GameMode.is_world_server() or _database() == null: return
	_tick_elapsed += delta
	if _tick_elapsed < 0.2: return
	_tick_elapsed = fmod(_tick_elapsed, 0.2)
	var now: int = Time.get_ticks_msec()
	for id: int in ground.keys():
		if now >= int(ground[id].expires):
			ground.erase(id)
			continue
		# Rights filter reserved loot; public loot goes to the first eligible peer.
		for peer_id: int in _world.characters:
			var result: Dictionary = pickup_for_peer(peer_id, id, now, AUTO_REACH)
			if result.ok:
				receive_feedback.rpc_id(peer_id, result)
				break
	_send_snapshot()

func _send_snapshot(only_peer: int = -1) -> void:
	if _database() == null: return
	var now: int = Time.get_ticks_msec()
	for peer_id: int in _world.characters:
		if only_peer != -1 and peer_id != only_peer: continue
		var drops: Dictionary = {}
		for id: int in ground:
			var drop: Dictionary = ground[id]
			drops[id] = {"amount": drop.amount, "position": drop.position,
				"allowed": now >= int(drop.protected_until) or _owner(peer_id) == int(drop.owner),
				"reserved_for": drop.owner_name if now < int(drop.protected_until) else ""}
		receive_state.rpc_id(peer_id, {"balance": _database().wallet_balance(_owner(peer_id)), "drops": drops})

@rpc("authority", "call_remote", "reliable", 0)
func receive_state(snapshot: Dictionary) -> void:
	if not GameMode.is_client(): return
	state = snapshot
	state_changed.emit(snapshot)
	for id: int in _visuals.keys():
		if not snapshot.drops.has(id):
			_visuals[id].queue_free()
			_visuals.erase(id)
	for id: int in snapshot.drops:
		var drop: Dictionary = snapshot.drops[id]
		if not _visuals.has(id):
			var node := Node3D.new()
			node.position = drop.position
			_world.add_child(node)
			var mesh := MeshInstance3D.new()
			var coin := CylinderMesh.new()
			coin.top_radius = 0.22
			coin.bottom_radius = 0.22
			coin.height = 0.1
			mesh.mesh = coin
			mesh.position.y = 0.12
			var material := StandardMaterial3D.new()
			material.albedo_color = Color("ffce45")
			mesh.material_override = material
			node.add_child(mesh)
			var label := Label3D.new()
			label.name = "Amount"
			label.position.y = 1.4
			label.font_size = 28
			label.pixel_size = 0.01
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			node.add_child(label)
			_visuals[id] = node
		var label: Label3D = _visuals[id].get_node("Amount")
		label.text = "%d Yang" % int(drop.amount) + ("\n" + str(drop.reserved_for) if drop.reserved_for != "" else "")
		label.modulate = Color("ffe291") if drop.allowed else Color("e0a681")
	_refresh_hud()

@rpc("authority", "call_remote", "reliable", 1)
func receive_feedback(result: Dictionary) -> void:
	if not GameMode.is_client(): return
	if result.ok:
		_notice = "Wydano %d Yang" % int(result.spent) if result.has("spent") else "+%d Yang" % int(result.amount)
	else:
		match str(result.error):
			"funds": _notice = "Za mało Yang."
			"reserved": _notice = "Yang zarezerwowane dla innego gracza."
			"distance": _notice = "Podejdź bliżej Yang."
			"gone": _notice = "Yang już zabrane lub wygasło."
			"too_fast", "replay": _notice = "Odczekaj przed kolejną operacją."
			_: _notice = "Operacja nie powiodła się. Spróbuj ponownie."
	_refresh_hud()
	feedback_received.emit(result)

func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.offset_left = -310
	panel.offset_right = -20
	panel.offset_top = -140
	panel.offset_bottom = -20
	canvas.add_child(panel)
	var content := VBoxContainer.new()
	panel.add_child(content)
	_balance_label = Label.new()
	_balance_label.add_theme_font_size_override("font_size", 22)
	content.add_child(_balance_label)
	var hint := Label.new()
	hint.text = "Auto-pickup Yang · G: podnieś"
	content.add_child(hint)
	_notice_label = Label.new()
	content.add_child(_notice_label)
	var button := Button.new()
	button.text = "Test: wydaj %d Yang" % TEST_SPEND_COST
	button.pressed.connect(func() -> void:
		_client_sequence += 1
		request_test_spend.rpc_id(1, _client_sequence))
	content.add_child(button)
	_refresh_hud()

func _refresh_hud() -> void:
	if _balance_label == null: return
	var balance: int = int(state.get("balance", -1))
	_balance_label.text = "%d Yang" % balance if balance >= 0 else "Yang: niedostępne"
	_notice_label.text = _notice

func _unhandled_key_input(event: InputEvent) -> void:
	if not GameMode.is_client() or not _world.input_enabled or ClientState.menu_open: return
	if not event is InputEventKey or not event.pressed or event.echo or event.physical_keycode != KEY_G: return
	if not _world.characters.has(_world.local_peer): return
	var nearest: float = INF
	var selected: int = 0
	for id: int in state.get("drops", {}):
		var distance: float = _world.characters[_world.local_peer].position.distance_to(state.drops[id].position)
		if distance < nearest:
			nearest = distance
			selected = id
	if selected > 0: request_pickup.rpc_id(1, selected)
	get_viewport().set_input_as_handled()
