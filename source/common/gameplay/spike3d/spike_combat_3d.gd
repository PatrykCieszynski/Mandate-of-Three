class_name SpikeCombat3D
extends Node
## Facing-based melee: no target ID or hit list is accepted from a client.

const MOB_HP: int = 120
const HOME: Vector3 = Vector3(-4, 0, 0)
const AGGRO: float = 6.0
const LEASH: float = 12.0
const MOB_REACH: float = 1.65
const ATTACK_REACH: float = 2.4
const HALF_ANGLE: float = 65.0
const PICKUP_REACH: float = 2.5
const COMBO_RECOVERY: Array[int] = [450, 450, 700]
const COMBO_IMPACT: Array[int] = [120, 140, 180]
const COMBO_RESET_MS: int = 1100
const PROTECTION_MS: int = 15000
const LOOT_LIFETIME_MS: int = 120000
const DOG_XP: int = 20

signal feedback_received(result: Dictionary)
var dogs: Dictionary[int, SpikeWildDog3D] = {}
var ground: Dictionary[String, Dictionary] = {}
var health: Dictionary[int, int] = {}
var _respawn_ms: Dictionary[int, int] = {}
var _next_attack_ms: Dictionary[int, int] = {}
var _combo: Dictionary[int, int] = {}
var _last_swing_ms: Dictionary[int, int] = {}
var _pending: Dictionary[int, Dictionary] = {}
var _sequences: Dictionary[int, int] = {}
var _pickup_ms: Dictionary[int, int] = {}
var _snapshot_accum: float = 0
var _world: SpikeWorld3D
var _hud: Label
var _notice: String = ""
var _visual_drops: Dictionary[String, Node3D] = {}
var _client_sequence: int = 0
var _client_attack_accum: float = 0
var selected_mob: int = 0
var autoattack: bool = false
var state: Dictionary = {}
var navigation_region: NavigationRegion3D
var _experience_label: Label
var _experience_bar: ProgressBar
var _xp_notice: String = ""
var _xp_notice_until_ms: int = 0

func _ready() -> void:
	_world = get_parent()
	if GameMode.is_world_server(): _build_navigation()
	var homes: Array[Vector3] = [HOME, Vector3(-2, 0, -1), Vector3(-6, 0, -1), Vector3(-4, 0, -3)]
	for i: int in homes.size():
		var dog := SpikeWildDog3D.new()
		dog.name = "WildDog_%d" % (i + 1)
		dog.setup_dog(i + 1, homes[i])
		_world.add_child(dog)
		dogs[i + 1] = dog
	if GameMode.is_client():
		var canvas := CanvasLayer.new()
		add_child(canvas)
		var panel := PanelContainer.new()
		panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
		panel.offset_left = 20
		panel.offset_top = -215
		panel.offset_right = 440
		panel.offset_bottom = -20
		canvas.add_child(panel)
		var content := VBoxContainer.new()
		panel.add_child(content)
		_hud = Label.new()
		_hud.add_theme_font_size_override("font_size", 16)
		content.add_child(_hud)
		_experience_label = Label.new()
		content.add_child(_experience_label)
		_experience_bar = ProgressBar.new()
		_experience_bar.custom_minimum_size = Vector2(400, 14)
		_experience_bar.show_percentage = false
		content.add_child(_experience_bar)
		_refresh_hud()

func _build_navigation() -> void:
	var mesh := NavigationMesh.new()
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_collision_mask = 1
	mesh.agent_radius = 0.5
	mesh.agent_height = 1.2
	mesh.agent_max_climb = 0.2
	mesh.cell_size = 0.125
	mesh.cell_height = 0.1
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(mesh, source, _world)
	NavigationServer3D.bake_from_source_geometry_data(mesh, source)
	navigation_region = NavigationRegion3D.new()
	navigation_region.navigation_mesh = mesh
	_world.add_child(navigation_region)

func _store() -> ItemStoreSqlite:
	return _world.inventory_endpoint._store()

func initialize_peer(peer_id: int) -> void:
	health[peer_id] = 100
	_send_snapshot()

func remove_peer(peer_id: int) -> void:
	for collection: Dictionary in [health, _respawn_ms, _next_attack_ms, _combo, _last_swing_ms, _pending, _sequences, _pickup_ms]:
		collection.erase(peer_id)
	for dog: SpikeWildDog3D in dogs.values():
		if dog.target_peer == peer_id:
			dog.target_peer = 0
			if dog.ai_state not in ["DEAD", "DISABLED"]: dog.ai_state = "RETURN"

func _owner(peer_id: int) -> int:
	var resource: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	return 0 if resource == null else resource.player_id

func _living(peer_id: int) -> bool:
	return _world.characters.has(peer_id) and health.get(peer_id, 0) > 0

func can_move(peer_id: int) -> bool:
	return health.get(peer_id, 100) > 0 and Time.get_ticks_msec() >= _next_attack_ms.get(peer_id, 0)

func _visible_between(from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 0.65, to + Vector3.UP * 0.65, 1)
	return _world.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

@rpc("any_peer", "call_remote", "reliable", 1)
func request_attack(sequence: int) -> void:
	if not GameMode.is_world_server() or _store() == null: return
	begin_attack(multiplayer.get_remote_sender_id(), sequence, Time.get_ticks_msec())

func begin_attack(peer_id: int, sequence: int, now: int) -> bool:
	if not _living(peer_id) or sequence < 0 or sequence > 2147483647 or sequence <= _sequences.get(peer_id, -1): return false
	if _owner(peer_id) <= 0: return false
	_sequences[peer_id] = sequence
	if now < _next_attack_ms.get(peer_id, 0): return false
	var attack: int = WorldServer.curr.runtime_attack(_owner(peer_id))
	if attack < 0: return false
	var stage: int = 1
	if now - _last_swing_ms.get(peer_id, -10000) <= COMBO_RESET_MS:
		stage = _combo.get(peer_id, 0) % 3 + 1
	_combo[peer_id] = stage
	_last_swing_ms[peer_id] = now
	_next_attack_ms[peer_id] = now + COMBO_RECOVERY[stage - 1]
	_pending[peer_id] = {"stage": stage, "yaw": _world.characters[peer_id].rotation.y,
		"impact": now + COMBO_IMPACT[stage - 1], "attack": attack}
	for observer: int in _world.characters:
		receive_swing.rpc_id(observer, peer_id, stage)
	return true

func resolve_swing(peer_id: int, swing: Dictionary, now: int) -> Array[int]:
	var hit_ids: Array[int] = []
	if not _living(peer_id): return hit_ids
	var body: SpikeCharacter3D = _world.characters[peer_id]
	var yaw: float = swing.yaw
	var forward := Vector3(-sin(yaw), 0, -cos(yaw))
	var shape := SphereShape3D.new()
	shape.radius = ATTACK_REACH + 0.4
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, body.position + Vector3.UP * 0.5)
	query.collision_mask = 4
	for hit: Dictionary in _world.get_world_3d().direct_space_state.intersect_shape(query, 64):
		var dog: SpikeWildDog3D = hit.collider as SpikeWildDog3D
		if dog == null or hit_ids.has(dog.mob_id) or dog.ai_state in ["DEAD", "RETURN", "DISABLED"]: continue
		var offset: Vector3 = dog.position - body.position
		var horizontal := Vector3(offset.x, 0, offset.z)
		if horizontal.length() > ATTACK_REACH or absf(offset.y) > 1.2: continue
		if horizontal.length_squared() > 0.001 and horizontal.normalized().dot(forward) < cos(deg_to_rad(HALF_ANGLE)): continue
		if not _visible_between(body.position, dog.position): continue
		var damage: int = clampi(int(swing.attack * (1.5 if int(swing.stage) == 3 else 1.0)), 0, dog.hp)
		if damage <= 0: continue
		hit_ids.append(dog.mob_id)
		dog.hp -= damage
		var owner_id: int = _owner(peer_id)
		dog.contributions[owner_id] = dog.contributions.get(owner_id, 0) + damage
		dog.contribution_players[owner_id] = WorldServer.curr.connected_players[peer_id]
		if dog.hp == 0:
			_die(dog, now)
		else:
			dog.ai_state = "CHASE"
			dog.target_peer = peer_id
			dog.stunned_until_ms = now + (350 if int(swing.stage) == 3 else 120)
			if int(swing.stage) == 3: dog.knockback = horizontal.normalized() * 7.0
	for observer: int in _world.characters:
		receive_hits.rpc_id(observer, peer_id, hit_ids)
	return hit_ids

func _die(dog: SpikeWildDog3D, now: int) -> void:
	if dog.ai_state == "DEAD": return
	dog.die(now)
	var owner_id: int = 0
	var highest: int = -1
	for contributor: int in dog.contributions:
		if dog.contributions[contributor] > highest or (dog.contributions[contributor] == highest and contributor < owner_id):
			owner_id = contributor
			highest = dog.contributions[contributor]
	var owner_name: String = ""
	for peer_id: int in _world.characters:
		if _owner(peer_id) == owner_id: owner_name = WorldServer.curr.connected_players[peer_id].display_name
	var uid: String = Crypto.new().generate_random_bytes(16).hex_encode()
	ground[uid] = {"position": dog.position, "definition_id": "iron_sword", "bonus": randi_range(1, 9),
		"owner": owner_id, "owner_name": owner_name, "protected_until": now + PROTECTION_MS, "expires": now + LOOT_LIFETIME_MS}
	_world.currency_endpoint.spawn_currency(dog.position, owner_id, owner_name, now)
	if owner_id > 0:
		_award_experience(dog.contribution_players.get(owner_id))
	dog.contribution_players.clear()

func _award_experience(resource: PlayerResource) -> void:
	if resource == null: return
	# A contributor may have disconnected/relogged before the killing blow.
	# Always use the current in-process resource rather than an old encounter ref.
	resource = WorldServer.curr.database.dirty_progression.get(resource.player_id, resource)
	for current: PlayerResource in WorldServer.curr.connected_players.values():
		if current.player_id == resource.player_id:
			resource = current
			break
	var result: Dictionary = resource.add_experience(DOG_XP)
	WorldServer.curr.database.mark_progression_dirty(resource)
	for peer_id: int in WorldServer.curr.connected_players:
		if WorldServer.curr.connected_players[peer_id] != resource: continue
		if _world.characters.has(peer_id):
			receive_experience.rpc_id(peer_id, DOG_XP, int(result.levels_gained), int(result.level))

@rpc("authority", "call_remote", "reliable", 0)
func receive_experience(amount: int, levels_gained: int, level: int) -> void:
	if not GameMode.is_client(): return
	_xp_notice = "+%d XP" % amount
	if levels_gained > 0: _xp_notice += " · Awans! Poziom %d" % level
	_xp_notice_until_ms = Time.get_ticks_msec() + 5000
	_refresh_hud()

@rpc("authority", "call_remote", "reliable", 0)
func receive_swing(peer_id: int, stage: int) -> void:
	if not GameMode.is_client(): return
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null: body.play_swing(stage)

@rpc("authority", "call_remote", "reliable", 0)
func receive_hits(peer_id: int, mob_ids: Array[int]) -> void:
	if not GameMode.is_client(): return
	for id: int in mob_ids:
		if dogs.has(id): dogs[id].play_hit()
	if peer_id == _world.local_peer:
		_notice = "Trafiono: %d" % mob_ids.size()
		_refresh_hud()

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
	if result.ok:
		result["item_name"] = ItemDefinitions.IRON_SWORD.item_name
		result["weapon_attack"] = int(ItemDefinitions.IRON_SWORD.base_stats[&"attack"]) + int(drop.bonus)
	if result.ok or result.get("error", "") == "claimed": ground.erase(uid)
	return result

func _reply(peer_id: int, result: Dictionary) -> void:
	receive_feedback.rpc_id(peer_id, result)

@rpc("authority", "call_remote", "reliable", 1)
func receive_feedback(result: Dictionary) -> void:
	if GameMode.is_world_server(): return
	match str(result.get("error", "")):
		"": _notice = "Podniesiono: %s · atak %d · I: porównaj" % [result.get("item_name", "Żelazny miecz"), int(result.get("weapon_attack", 0))]
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
			var body: SpikeCharacter3D = _world.characters[peer_id]
			body.position = Vector3(-3, 0.1, 3)
			body.velocity = Vector3.ZERO
			_world.intentions[peer_id]["direction"] = Vector2.ZERO
			_respawn_ms.erase(peer_id)
	for peer_id: int in _pending.keys():
		if now >= int(_pending[peer_id].impact):
			var swing: Dictionary = _pending[peer_id]
			_pending.erase(peer_id)
			resolve_swing(peer_id, swing, now)
	for dog: SpikeWildDog3D in dogs.values(): _tick_dog(dog, delta, now)
	_snapshot_accum += delta
	if _snapshot_accum >= 0.1:
		_snapshot_accum = fmod(_snapshot_accum, 0.1)
		_send_snapshot()

func hurt_player(peer_id: int, damage: int, now: int) -> void:
	if not _living(peer_id): return
	health[peer_id] = maxi(0, health[peer_id] - damage)
	for observer: int in _world.characters: receive_hurt.rpc_id(observer, peer_id)
	if health[peer_id] == 0:
		_respawn_ms[peer_id] = now + 2000
		_pending.erase(peer_id)
		_combo.erase(peer_id)
		_last_swing_ms.erase(peer_id)
		_next_attack_ms.erase(peer_id)
		_world.intentions[peer_id]["direction"] = Vector2.ZERO
		_send_snapshot()

@rpc("authority", "call_remote", "reliable", 0)
func receive_hurt(peer_id: int) -> void:
	if not GameMode.is_client(): return
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null: body.play_hit()

func _tick_dog(dog: SpikeWildDog3D, delta: float, now: int) -> void:
	if not dog.ai_enabled: return
	if dog.ai_state == "DISABLED": return
	if dog.ai_state == "DEAD":
		if now >= dog.dead_until_ms: dog.respawn()
		return
	if dog.ai_state == "IDLE":
		var nearest: float = AGGRO
		for peer_id: int in _world.characters:
			var distance: float = dog.position.distance_to(_world.characters[peer_id].position)
			if _living(peer_id) and distance < nearest:
				dog.target_peer = peer_id
				nearest = distance
		if dog.target_peer != 0: dog.ai_state = "CHASE"
	if dog.ai_state in ["CHASE", "ATTACK"]:
		if not _living(dog.target_peer) or dog.position.distance_to(dog.home) > LEASH or _world.characters[dog.target_peer].position.distance_to(dog.home) > LEASH:
			dog.ai_state = "RETURN"
			dog.target_peer = 0
	var direction := Vector2.ZERO
	if dog.ai_state in ["CHASE", "ATTACK"]:
		var body: SpikeCharacter3D = _world.characters[dog.target_peer]
		if dog.position.distance_to(body.position) > MOB_REACH or not _visible_between(dog.position, body.position):
			dog.ai_state = "CHASE"
			direction = dog.navigate(body.position, now)
		else:
			dog.ai_state = "ATTACK"
			var offset: Vector3 = body.position - dog.position
			dog.rotation.y = atan2(-offset.x, -offset.z)
			if now >= dog.stunned_until_ms and now - dog.last_attack_ms >= 1200:
				dog.last_attack_ms = now
				hurt_player(dog.target_peer, 6, now)
	elif dog.ai_state == "RETURN":
		if Vector2(dog.position.x - dog.home.x, dog.position.z - dog.home.z).length() < 0.25:
			dog.hp = MOB_HP
			dog.contributions.clear()
			dog.contribution_players.clear()
			dog.ai_state = "IDLE"
		else:
			direction = dog.navigate(dog.home, now)
	dog.move_dog(delta, direction, now)
	dog.hp_label.text = "%d / %d" % [dog.hp, MOB_HP]

func _send_snapshot() -> void:
	if _store() == null: return
	var now: int = Time.get_ticks_msec()
	var mob_snapshots: Dictionary = {}
	for id: int in dogs:
		var dog: SpikeWildDog3D = dogs[id]
		mob_snapshots[id] = {"position": dog.position, "yaw": dog.rotation.y, "hp": dog.hp, "state": dog.ai_state}
	var respawns: Dictionary = {}
	var levels: Dictionary = {}
	for id: int in _world.characters:
		levels[id] = WorldServer.curr.connected_players[id].level
	for id: int in _respawn_ms: respawns[id] = maxf(0, (_respawn_ms[id] - now) / 1000.0)
	for peer_id: int in _world.characters:
		var drops: Dictionary = {}
		for uid: String in ground:
			var drop: Dictionary = ground[uid]
			drops[uid] = {"position": drop.position, "definition_id": drop.definition_id,
				"item_name": ItemDefinitions.IRON_SWORD.item_name,
				"weapon_attack": int(ItemDefinitions.IRON_SWORD.base_stats[&"attack"]) + int(drop.bonus),
				"reserved_for": drop.owner_name if now < int(drop.protected_until) else "",
				"allowed": now >= int(drop.protected_until) or _owner(peer_id) == int(drop.owner)}
		var player: PlayerResource = WorldServer.curr.connected_players[peer_id]
		receive_state.rpc_id(peer_id, {"dogs": mob_snapshots, "health": health.duplicate(), "drops": drops,
			"combos": _combo.duplicate(), "respawns": respawns, "levels": levels,
			"progression": {"level": player.level, "experience": player.experience, "next": player.level_xp_to_next()}})

@rpc("authority", "call_remote", "reliable", 0)
func receive_state(snapshot: Dictionary) -> void:
	if GameMode.is_world_server(): return
	state = snapshot
	for peer_id: int in snapshot.levels:
		var player: SpikeCharacter3D = _world.characters.get(peer_id)
		if player != null: player.set_level(int(snapshot.levels[peer_id]))
	for id: int in snapshot.dogs:
		if dogs.has(id): dogs[id].present_snapshot(snapshot.dogs[id])
	for peer_id: int in snapshot.health:
		var body: SpikeCharacter3D = _world.characters.get(peer_id)
		if body != null: body.set_alive(int(snapshot.health[peer_id]) > 0)
	if int(snapshot.health.get(_world.local_peer, 0)) <= 0: autoattack = false
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
		label.text = "%s · Atak %d · E" % [drop.item_name, int(drop.weapon_attack)] + ("\n" + str(drop.reserved_for) if drop.reserved_for != "" else "")
		label.modulate = Color("ffe291") if drop.allowed else Color("e0a681")
	_refresh_hud()

func _refresh_hud() -> void:
	if _hud == null: return
	var hp: int = int(state.get("health", {}).get(_world.local_peer, 100))
	var target: String = "Brak celu"
	if dogs.has(selected_mob):
		target = "Wild Dog: %d / %d" % [dogs[selected_mob].hp, MOB_HP]
	var combo: int = int(state.get("combos", {}).get(_world.local_peer, 0))
	var status: String = "Odrodzenie za %.1f s" % float(state.get("respawns", {}).get(_world.local_peer, 0)) if hp == 0 else _notice
	_hud.text = "HP: %d / 100 · Combo: %d / 3\nSpacja — combo · E — łup\nLPM — cel · F — autoatak (%s)\n%s · %s" % [hp, combo, "wł." if autoattack else "wył.", target, status]
	var progression: Dictionary = state.get("progression", {"level": 1, "experience": 0, "next": PlayerResource.LEVEL_XP_BASE})
	_experience_label.text = "Poziom %d · XP: %d / %d%s" % [int(progression.level), int(progression.experience), int(progression.next), "\n" + _xp_notice if _xp_notice != "" else ""]
	_experience_bar.max_value = int(progression.next)
	_experience_bar.value = int(progression.experience)

func select_mob(id: int) -> void:
	selected_mob = id if dogs.has(id) and dogs[id].ai_state not in ["DEAD", "DISABLED"] else 0
	for dog: SpikeWildDog3D in dogs.values(): dog.mark_selected(dog.mob_id == selected_mob)
	if selected_mob == 0: autoattack = false
	_refresh_hud()

func _unhandled_input(event: InputEvent) -> void:
	if not GameMode.is_client() or not _world.input_enabled or ClientState.menu_open: return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var camera: Camera3D = _world._camera
		var origin: Vector3 = camera.project_ray_origin(event.position)
		var ray := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(event.position) * 100, 4)
		var hit: Dictionary = _world.get_world_3d().direct_space_state.intersect_ray(ray)
		var dog: SpikeWildDog3D = hit.get("collider") as SpikeWildDog3D
		select_mob(0 if dog == null else dog.mob_id)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F:
			autoattack = not autoattack and selected_mob != 0
			_refresh_hud()
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

func assist_direction(manual: Vector2) -> Vector2:
	if manual.length_squared() > 0.001:
		autoattack = false
		return manual
	if not autoattack or not dogs.has(selected_mob) or not _world.characters.has(_world.local_peer): return manual
	var dog: SpikeWildDog3D = dogs[selected_mob]
	if dog.ai_state in ["DEAD", "DISABLED"]:
		autoattack = false
		return Vector2.ZERO
	var body: SpikeCharacter3D = _world.characters[_world.local_peer]
	var offset: Vector3 = dog.position - body.position
	var direction := Vector2(offset.x, offset.z).normalized()
	if Vector2(offset.x, offset.z).length() > 1.7: return direction
	var forward := Vector2(-sin(body.rotation.y), -cos(body.rotation.y))
	return direction * 0.05 if forward.dot(direction) < 0.98 else Vector2.ZERO

func _process(delta: float) -> void:
	if not GameMode.is_client(): return
	if _xp_notice != "" and Time.get_ticks_msec() >= _xp_notice_until_ms:
		_xp_notice = ""
		_refresh_hud()
	for dog: SpikeWildDog3D in dogs.values(): dog.interpolate(delta)
	if not _world.input_enabled or ClientState.menu_open or not DisplayServer.window_is_focused(): return
	_client_attack_accum += delta
	var active: bool = Input.is_physical_key_pressed(KEY_SPACE)
	if autoattack and dogs.has(selected_mob) and _world.characters.has(_world.local_peer):
		active = dogs[selected_mob].ai_state not in ["DEAD", "DISABLED"] and _world.characters[_world.local_peer].position.distance_to(dogs[selected_mob].position) <= ATTACK_REACH
	if active and _client_attack_accum >= 0.1:
		_client_attack_accum = 0
		_client_sequence += 1
		request_attack.rpc_id(1, _client_sequence)
