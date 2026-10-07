class_name SpikeCombat3D
extends Node
## One technical mob and ground loot. All decisions and item writes live on the
## authenticated world server; clients send attack/pickup intentions only.

const MOB_ID: int = 1
const MOB_HP: int = 120
const HOME: Vector3 = Vector3(-4, 0, 0)
const AGGRO: float = 6.0
const LEASH: float = 10.0
const MOB_REACH: float = 1.8
const ATTACK_REACH: float = 2.4
const PICKUP_REACH: float = 2.5
const ATTACK_COOLDOWN_MS: int = 600
const PROTECTION_MS: int = 15000
const LOOT_LIFETIME_MS: int = 120000

signal feedback_received(result: Dictionary)
var mob: SpikeCharacter3D
var mob_hp: int = MOB_HP
var mob_state: String = "IDLE"
var target_peer: int = 0
var dead_until_ms: int = 0
var ground: Dictionary[String, Dictionary] = {}
var health: Dictionary[int, int] = {}
var contributions: Dictionary[int, int] = {} # persistent character ID -> damage
var _respawn_ms: Dictionary[int, int] = {}
var _attack_ms: Dictionary[int, int] = {}
var _sequences: Dictionary[int, int] = {}
var _pickup_ms: Dictionary[int, int] = {}
var _mob_attack_ms: int = -1000
var _snapshot_accum: float = 0
var _world: SpikeWorld3D
var _label: Label3D
var _hud: Label
var _notice: String = ""
var _visual_drops: Dictionary[String, Node3D] = {}
var _client_sequence: int = 0
var state: Dictionary = {}

func _ready() -> void:
	_world = get_parent()
	mob = SpikeCharacter3D.new()
	mob.name = "TrainingMob"
	mob.setup("Dziki strażnik", Color("bc5b4b"))
	_world.add_child(mob)
	mob.position = HOME
	_label = Label3D.new()
	_label.position.y = 2.7
	_label.font_size = 36
	_label.pixel_size = 0.01
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mob.add_child(_label)
	_label.text = "120 / 120"
	if GameMode.is_client():
		var canvas := CanvasLayer.new()
		add_child(canvas)
		var panel := PanelContainer.new()
		panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
		panel.offset_left = 20
		panel.offset_top = -110
		panel.offset_right = 420
		panel.offset_bottom = -20
		canvas.add_child(panel)
		_hud = Label.new()
		_hud.add_theme_font_size_override("font_size", 16)
		panel.add_child(_hud)
		_refresh_hud()

func _store() -> ItemStoreSqlite:
	return _world.inventory_endpoint._store()

func initialize_peer(peer_id: int) -> void:
	health[peer_id] = 100
	_send_snapshot()

func remove_peer(peer_id: int) -> void:
	health.erase(peer_id)
	_respawn_ms.erase(peer_id)
	_attack_ms.erase(peer_id)
	_sequences.erase(peer_id)
	_pickup_ms.erase(peer_id)
	if target_peer == peer_id:
		target_peer = 0
		if mob_state != "DEAD": mob_state = "RETURN"

func _owner(peer_id: int) -> int:
	var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	return 0 if resource == null else resource.player_id

func _living(peer_id: int) -> bool:
	return _world.characters.has(peer_id) and health.get(peer_id, 0) > 0

func _visible_between(from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 0.9, to + Vector3.UP * 0.9, 1)
	return _world.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

@rpc("any_peer", "call_remote", "reliable", 1)
func request_attack(sequence: int, mob_id: int) -> void:
	if not GameMode.is_world_server() or _store() == null:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _living(peer_id) or mob_id != MOB_ID or sequence < 0 or sequence > 2147483647 or sequence <= _sequences.get(peer_id, -1):
		return
	_sequences[peer_id] = sequence
	var now: int = Time.get_ticks_msec()
	if mob_state in ["DEAD", "RETURN"] or now - _attack_ms.get(peer_id, -1000) < ATTACK_COOLDOWN_MS:
		return
	var body: SpikeCharacter3D = _world.characters[peer_id]
	if body.position.distance_to(mob.position) > ATTACK_REACH or not _visible_between(body.position, mob.position):
		return
	var inventory: Dictionary = _store().inventory(_owner(peer_id))
	if not inventory.ok: return
	_attack_ms[peer_id] = now
	var damage: int = clampi(int(inventory.stats.attack), 0, mob_hp)
	if damage == 0: return
	mob_hp -= damage
	var owner_id: int = _owner(peer_id)
	contributions[owner_id] = contributions.get(owner_id, 0) + damage
	if mob_hp == 0:
		_die(now)
	else:
		target_peer = peer_id
		mob_state = "CHASE"
	_send_snapshot()

func _die(now: int) -> void:
	mob_state = "DEAD"
	target_peer = 0
	dead_until_ms = now + 6000
	mob.visible = false
	var owner_id: int = 0
	var highest: int = -1
	for contributor: int in contributions:
		if contributions[contributor] > highest or (contributions[contributor] == highest and contributor < owner_id):
			owner_id = contributor
			highest = contributions[contributor]
	var owner_name: String = ""
	for peer_id: int in _world.characters:
		if _owner(peer_id) == owner_id:
			owner_name = WorldServer.curr.connected_players[peer_id].display_name
	var uid: String = Crypto.new().generate_random_bytes(16).hex_encode()
	ground[uid] = {"position": mob.position, "definition_id": "iron_sword", "bonus": randi_range(1, 9),
		"owner": owner_id, "owner_name": owner_name, "protected_until": now + PROTECTION_MS, "expires": now + LOOT_LIFETIME_MS}

@rpc("any_peer", "call_remote", "reliable", 1)
func request_pickup(uid: String) -> void:
	if not GameMode.is_world_server() or _store() == null:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _living(peer_id): return
	var now: int = Time.get_ticks_msec()
	if now - _pickup_ms.get(peer_id, -1000) < 100:
		_reply(peer_id, {"ok": false, "error": "too_fast"})
		return
	_pickup_ms[peer_id] = now
	var result: Dictionary = pickup_for_peer(peer_id, uid, now)
	_reply(peer_id, result)
	if result.ok:
		_world.inventory_endpoint._send_state(peer_id)
		_send_snapshot()

func pickup_for_peer(peer_id: int, uid: String, now: int) -> Dictionary:
	# Synchronous: another RPC cannot interleave between commit and ground erase.
	if not ItemStoreSqlite.valid_uid(uid) or not ground.has(uid):
		return {"ok": false, "error": "gone"}
	var drop: Dictionary = ground[uid]
	if now >= int(drop.expires):
		ground.erase(uid)
		return {"ok": false, "error": "gone"}
	var owner_id: int = _owner(peer_id)
	if now < int(drop.protected_until) and owner_id != int(drop.owner):
		return {"ok": false, "error": "reserved"}
	var body: SpikeCharacter3D = _world.characters[peer_id]
	if body.position.distance_to(drop.position) > PICKUP_REACH or not _visible_between(body.position, drop.position):
		return {"ok": false, "error": "distance"}
	var result: Dictionary = _store().claim_ground_item(owner_id, uid, int(drop.bonus))
	if result.ok or result.get("error", "") == "claimed": ground.erase(uid)
	return result

func _reply(peer_id: int, result: Dictionary) -> void:
	receive_feedback.rpc_id(peer_id, result)

@rpc("authority", "call_remote", "reliable", 1)
func receive_feedback(result: Dictionary) -> void:
	if GameMode.is_world_server(): return
	match str(result.get("error", "")):
		"": _notice = "Podniesiono żelazny miecz."
		"reserved": _notice = "Łup jest jeszcze zarezerwowany dla innego gracza."
		"distance": _notice = "Podejdź bliżej łupu."
		"bag_full": _notice = "Torba jest pełna. Łup pozostaje na ziemi."
		"gone", "claimed": _notice = "Ten łup został już zabrany lub zniknął."
		"too_fast": _notice = "Odczekaj chwilę przed kolejną próbą."
		_: _notice = "Nie udało się zapisać przedmiotu. Spróbuj ponownie."
	_refresh_hud()
	feedback_received.emit(result)

func _physics_process(delta: float) -> void:
	if not GameMode.is_world_server() or _store() == null: return
	var now: int = Time.get_ticks_msec()
	for uid: String in ground.keys():
		if now >= int(ground[uid].expires): ground.erase(uid)
	for peer_id: int in _respawn_ms.keys():
		if now >= _respawn_ms[peer_id] and _world.characters.has(peer_id):
			health[peer_id] = 100
			_world.characters[peer_id].position = Vector3(-3, 0.1, 3)
			_respawn_ms.erase(peer_id)
	_tick_mob(delta, now)
	_snapshot_accum += delta
	if _snapshot_accum >= 0.1:
		_snapshot_accum = fmod(_snapshot_accum, 0.1)
		_send_snapshot()

func _tick_mob(delta: float, now: int) -> void:
	if mob_state == "DEAD":
		if now >= dead_until_ms:
			mob.position = HOME
			mob_hp = MOB_HP
			contributions.clear()
			mob_state = "IDLE"
			mob.visible = true
		return
	if mob_state == "IDLE":
		var nearest: float = AGGRO
		for peer_id: int in _world.characters:
			var distance: float = mob.position.distance_to(_world.characters[peer_id].position)
			if _living(peer_id) and distance < nearest and _visible_between(mob.position, _world.characters[peer_id].position):
				target_peer = peer_id
				nearest = distance
		if target_peer != 0: mob_state = "CHASE"
	if mob_state in ["CHASE", "ATTACK"]:
		if not _living(target_peer) or mob.position.distance_to(HOME) > LEASH or _world.characters[target_peer].position.distance_to(HOME) > LEASH:
			mob_state = "RETURN"
			target_peer = 0
	var direction := Vector2.ZERO
	if mob_state in ["CHASE", "ATTACK"]:
		var body: SpikeCharacter3D = _world.characters[target_peer]
		var offset: Vector3 = body.position - mob.position
		if offset.length() > MOB_REACH or not _visible_between(mob.position, body.position):
			mob_state = "CHASE"
			direction = Vector2(offset.x, offset.z).normalized()
		else:
			mob_state = "ATTACK"
			if now - _mob_attack_ms >= 1000:
				_mob_attack_ms = now
				health[target_peer] = maxi(0, health[target_peer] - 4)
				if health[target_peer] == 0:
					_respawn_ms[target_peer] = now + 2000
	elif mob_state == "RETURN":
		var offset: Vector3 = HOME - mob.position
		if Vector2(offset.x, offset.z).length() < 0.15:
			mob_hp = MOB_HP
			contributions.clear()
			mob_state = "IDLE"
		else:
			direction = Vector2(offset.x, offset.z).normalized()
	mob.velocity.x = direction.x * 2.8
	mob.velocity.z = direction.y * 2.8
	mob.velocity.y = -0.5 if mob.is_on_floor() else mob.velocity.y - 20 * delta
	if direction.length_squared() > 0:
		mob.rotation.y = atan2(-direction.x, -direction.y)
	mob.move_and_slide()
	_label.text = "%d / %d" % [mob_hp, MOB_HP]

func _send_snapshot() -> void:
	if _store() == null: return
	var now: int = Time.get_ticks_msec()
	for peer_id: int in _world.characters:
		var drops: Dictionary = {}
		for uid: String in ground:
			var drop: Dictionary = ground[uid]
			drops[uid] = {"position": drop.position, "definition_id": drop.definition_id,
				"reserved_for": drop.owner_name if now < int(drop.protected_until) else "",
				"allowed": now >= int(drop.protected_until) or _owner(peer_id) == int(drop.owner)}
		receive_state.rpc_id(peer_id, {"mob_position": mob.position, "mob_yaw": mob.rotation.y, "mob_hp": mob_hp,
			"mob_state": mob_state, "health": health.duplicate(), "drops": drops})

@rpc("authority", "call_remote", "reliable", 0)
func receive_state(snapshot: Dictionary) -> void:
	if GameMode.is_world_server(): return
	state = snapshot
	mob_hp = int(snapshot.mob_hp)
	mob_state = str(snapshot.mob_state)
	mob.visible = mob_state != "DEAD"
	mob.apply_snapshot(snapshot.mob_position, snapshot.mob_yaw)
	_label.text = "%d / %d" % [mob_hp, MOB_HP]
	for uid: String in _visual_drops.keys():
		if not snapshot.drops.has(uid):
			_visual_drops[uid].queue_free()
			_visual_drops.erase(uid)
	for uid: String in snapshot.drops:
		var drop: Dictionary = snapshot.drops[uid]
		if not _visual_drops.has(uid):
			var node := Node3D.new()
			_world.add_child(node)
			node.position = drop.position
			var mesh := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.18, 0.12, 0.8)
			mesh.mesh = box
			mesh.position.y = 0.2
			var material := StandardMaterial3D.new()
			material.albedo_color = Color("f3d36e")
			material.emission_enabled = true
			material.emission = Color("bb9035")
			mesh.material_override = material
			node.add_child(mesh)
			var label := Label3D.new()
			label.name = "Name"
			label.position.y = 3.0
			label.font_size = 32
			label.pixel_size = 0.012
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			node.add_child(label)
			_visual_drops[uid] = node
		var label: Label3D = _visual_drops[uid].get_node("Name")
		label.text = "Żelazny miecz · E" + ("\n" + str(drop.reserved_for) if drop.reserved_for != "" else "")
		label.modulate = Color("ffe291") if drop.allowed else Color("e0a681")
	_refresh_hud()

func _refresh_hud() -> void:
	if _hud == null: return
	var hp: int = int(state.get("health", {}).get(_world.local_peer, 100))
	_hud.text = "HP: %d / 100 · Strażnik: %d / %d\nSpacja — atak · E — podnieś najbliższy łup\n%s" % [hp, mob_hp, MOB_HP, _notice]

func _unhandled_key_input(event: InputEvent) -> void:
	if not GameMode.is_client() or not _world.input_enabled or ClientState.menu_open or not event is InputEventKey or not event.pressed or event.echo: return
	if event.physical_keycode == KEY_SPACE:
		_client_sequence += 1
		request_attack.rpc_id(1, _client_sequence, MOB_ID)
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_E:
		if not _world.characters.has(_world.local_peer): return
		var nearest: float = INF
		var selected: String = ""
		for uid: String in state.get("drops", {}):
			var distance: float = _world.characters[_world.local_peer].position.distance_to(state.drops[uid].position)
			if distance < nearest:
				nearest = distance
				selected = uid
		if selected != "": request_pickup.rpc_id(1, selected)
		get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not GameMode.is_world_server(): mob.interpolate(delta)
