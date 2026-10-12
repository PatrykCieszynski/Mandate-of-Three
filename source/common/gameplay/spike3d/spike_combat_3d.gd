class_name SpikeCombat3D
extends Node
var services: MandateWorldServices
## Facing-based melee: no target ID or hit list is accepted from a client.

const MOB_HP: int = 120
const HOME: Vector3 = Vector3(-4, 0, 0)

signal swing_received(peer_id: int, animation_key: StringName, step_index: int)
signal feedback_received(result: Dictionary)
signal state_changed(snapshot: Dictionary)
var attacks := BasicAttackService.new()
var client_combat := ClientCombatController.new()
var _pickup_ms: Dictionary[int, int] = {}
var _snapshot_accum: float = 0
var _world: SpikeWorld3D
var _hud: Label
var _notice: String = ""
var _visual_drops: Dictionary[String, Node3D] = {}
signal confirmed_hit_received(event: Dictionary)
var state: Dictionary = {}
var dev_god_mode: bool = false
var navigation_region: NavigationRegion3D
var _experience_label: Label
var _experience_bar: ProgressBar
var _xp_notice: String = ""
var _xp_notice_until_ms: int = 0

func _ready() -> void:
	_world = get_parent()
	attacks.setup(_world,self,services)
	client_combat.setup(_world,self)
	dev_god_mode = GameMode.is_world_server() and OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-god-mode")
	if dev_god_mode: print("DEV_GOD_MODE enabled for local World players")
	_build_navigation() # Shared geometry also guides client NPC approach intentions.
	if GameMode.is_world_server():
		if _world.region != null:
			for point: MobSpawnPoint3D in _world.region.find_children("*","MobSpawnPoint3D",true,false):
				assert(point.valid(),"Invalid mob spawn point: " + str(point.name))
				_world.mob_system.create_pack(point.members,_world.to_local(point.global_position),point.spawn_radius,point.wander_radius,point.leash_radius,point.respawn_seconds)
		else:
			# Small legacy arena fixture; same spawning path, singleton packs.
			var entry := MobSpawnEntry.new()
			entry.mob = preload("res://source/common/gameplay/mobs/wild_dog.tres")
			for home: Vector3 in [HOME,Vector3(-2,0,-1),Vector3(-6,0,-1),Vector3(-4,0,-3)]:
				_world.mob_system.create_pack([entry],home,0,0,12,6)
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
		refresh_hud()

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

func initialize_peer(peer_id: int) -> void:
	var body: SpikePlayer3D = _world.characters[peer_id]
	body.hp = body.max_hp
	body.set_alive(true)
	body.respawn_at_ms = 0
	attacks.attack_runtime(peer_id)
	if OS.has_feature("editor"):
		for arg: String in OS.get_cmdline_user_args():
			if arg.begins_with("--dev-combo-skill="): set_combo_skill_level(peer_id,arg.get_slice("=",1).to_int())
	_send_snapshot()

func remove_peer(peer_id: int) -> void:
	client_combat.remove_peer(peer_id)
	attacks.remove_peer(peer_id)
	_pickup_ms.erase(peer_id)
	var body: SpikePlayer3D = _world.characters.get(peer_id)
	if body != null:
		body.hp = 0
		body.set_alive(false)
		body.respawn_at_ms = 0
	_world.mob_system.remove_peer(peer_id)

func _owner(peer_id: int) -> int:
	var resource: PlayerResource = services.player_for_peer(peer_id)
	return 0 if resource == null else resource.player_id

func is_player_alive(peer_id: int) -> bool:
	var body: SpikePlayer3D = _world.characters.get(peer_id)
	return body != null and body.alive and body.hp > 0

func can_move(peer_id: int, now: int = Time.get_ticks_msec()) -> bool:
	var body: SpikePlayer3D = _world.characters.get(peer_id)
	return body != null and body.alive and body.hp > 0 and now >= attacks.movement_unlock(peer_id) and not body.hit_reaction.locked(now) and not body.knockback_active()

@rpc("any_peer", "call_remote", "reliable", 1)
func request_attack(sequence: int) -> void:
	if not GameMode.is_world_server() or not services.item_domain_ready(): return
	var peer_id := multiplayer.get_remote_sender_id()
	if not is_player_alive(peer_id): return
	var retry_ms: int = attacks.request_intent(peer_id,sequence,Time.get_ticks_msec())
	if retry_ms > 0: receive_attack_wait.rpc_id(peer_id,retry_ms)

@rpc("authority", "call_remote", "reliable", 0)
func receive_attack_wait(delay_ms: int) -> void:
	if GameMode.is_client(): client_combat.receive_attack_wait(delay_ms)

func combo_state(peer_id: int) -> BasicAttackComboState:
	return attacks.combo_state(peer_id)

func set_combo_skill_level(peer_id: int, level: int) -> bool:
	return attacks.set_combo_skill_level(peer_id,level)

func set_combo_enabled(peer_id: int, enabled: bool) -> bool:
	return attacks.set_combo_enabled(peer_id,enabled)

func set_combo_weapon_mode(peer_id: int, mode: StringName) -> bool:
	return attacks.set_combo_weapon_mode(peer_id,mode)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_combo_toggle() -> void:
	if not GameMode.is_world_server(): return
	var sender := multiplayer.get_remote_sender_id()
	if not is_player_alive(sender): return
	set_combo_enabled(sender,not combo_state(sender).combo_enabled)

func remember_next_facing(peer_id: int, direction: Vector2) -> void:
	attacks.remember_next_facing(peer_id,direction)

func publish_experience(owner_id: int, amount: int, levels_gained: int, level: int) -> void:
	for peer_id: int in _world.characters:
		if services.owner_id_for_peer(peer_id)==owner_id:
			receive_experience.rpc_id(peer_id,amount,levels_gained,level)

@rpc("authority", "call_remote", "reliable", 0)
func receive_experience(amount: int, levels_gained: int, level: int) -> void:
	if not GameMode.is_client(): return
	_xp_notice = "+%d XP" % amount
	if levels_gained > 0: _xp_notice += " · Awans! Poziom %d" % level
	_xp_notice_until_ms = Time.get_ticks_msec() + 5000
	refresh_hud()

@rpc("authority", "call_remote", "reliable", 0)
func receive_swing(peer_id: int, animation_key: StringName, step_index: int, motion_ms: int, finisher: bool, ratio: float = 1.0, action_id: int = 0, yaw: float = 0.0, preinput_ms: int = 0) -> void:
	if GameMode.is_client(): client_combat.receive_swing(peer_id,animation_key,step_index,motion_ms,finisher,ratio,action_id,yaw,preinput_ms)

@rpc("authority", "call_remote", "reliable", 0)
func receive_hits(peer_id: int, results: Array[Dictionary], action_id: int = 0, step_index: int = 0, finisher: bool = false) -> void:
	if GameMode.is_client(): client_combat.receive_hits(peer_id,results,action_id,step_index,finisher)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_pickup(uid: String) -> void:
	if not GameMode.is_world_server() or not services.item_domain_ready():
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not is_player_alive(peer_id): return
	var now: int = Time.get_ticks_msec()
	if now - _pickup_ms.get(peer_id, -1000) < 100:
		_reply(peer_id, {"ok": false, "error": "too_fast"})
		return
	_pickup_ms[peer_id] = now
	var result: Dictionary = pickup_for_peer(peer_id, uid, now)
	_reply(peer_id, result)
	if result.ok:
		_send_snapshot()

func pickup_for_peer(peer_id: int, uid: String, now: int) -> Dictionary:
	return _world.ground_loot.pickup_for_peer(peer_id,uid,now)

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
	refresh_hud()
	feedback_received.emit(result)

func _physics_process(delta: float) -> void:
	if not GameMode.is_world_server() or not services.item_domain_ready(): return
	var now: int = Time.get_ticks_msec()
	_world.ground_loot.expire(now)
	_tick_player_lifecycle(now)
	attacks.process_impacts(now)
	_world.mob_system.tick(delta,now)
	attacks.advance_queue(now)
	if _world.metin_encounter != null: _world.metin_encounter.tick(now)
	_snapshot_accum += delta
	if _snapshot_accum >= 0.1:
		_snapshot_accum = fmod(_snapshot_accum, 0.1)
		_send_snapshot()

func hurt_player(peer_id: int, damage: int, now: int, hit: AttackHitDefinition = BasicAttackHits.MOB_MELEE, hit_direction: Vector3 = Vector3.ZERO) -> CombatHitResult:
	if not is_player_alive(peer_id): return null
	if dev_god_mode: return CombatHitResult.new() # No damage, action lock or impulse.
	var body: SpikePlayer3D = _world.characters[peer_id]
	var result := HitReactionResolver.resolve(hit,body.reaction_profile,damage,body.hp,body.hit_reaction.locked(now))
	body.hp -= result.damage
	body.hit_reaction.apply(result,now)
	body.apply_knockback(hit_direction,result.knockback_distance)
	if result.interrupts_attack:
		attacks.interrupt(peer_id)
	for observer: int in _world.characters: receive_hurt.rpc_id(observer,peer_id,result.presentation())
	if body.hp == 0:
		body.set_alive(false)
		body.hit_reaction.clear()
		body.knockback_velocity = Vector3.ZERO
		body.respawn_at_ms = now + 2000
		attacks.interrupt(peer_id,true)
		_world.intentions[peer_id]["direction"] = Vector2.ZERO
		_send_snapshot()
	return result

@rpc("authority", "call_remote", "reliable", 0)
func receive_hurt(peer_id: int, result: Dictionary) -> void:
	if GameMode.is_client(): client_combat.receive_hurt(peer_id,result)

func _send_snapshot() -> void:
	if not services.item_domain_ready(): return
	var now: int = Time.get_ticks_msec()
	var mob_snapshots: Array = _world.mob_system.snapshot(now)
	var combos: Dictionary = attacks.combo_snapshot()
	var health: Dictionary = {}
	var respawns: Dictionary = {}
	var levels: Dictionary = {}
	var hit_locks: Dictionary = {}
	for id: int in _world.characters:
		health[id] = _world.characters[id].hp
		if _world.characters[id].respawn_at_ms > 0: respawns[id] = maxf(0,(_world.characters[id].respawn_at_ms-now)/1000.0)
		levels[id] = services.player_for_peer(id).level
		hit_locks[id] = _world.characters[id].hit_reaction.snapshot(now)
	for peer_id: int in _world.characters:
		var drops: Dictionary = _world.ground_loot.snapshot_for_peer(peer_id,now)
		var player: PlayerResource = services.player_for_peer(peer_id)
		receive_state.rpc_id(peer_id, {"mobs": mob_snapshots, "health": health.duplicate(), "drops": drops,
			"combo_options":{"enabled":combo_state(peer_id).combo_enabled,"skill_level":combo_state(peer_id).combo_skill_level,"length":combo_state(peer_id).definition().steps.size()},
			"combos": combos, "respawns": respawns, "levels": levels, "hit_locks":hit_locks,
			"metin": {} if _world.metin_encounter == null else _world.metin_encounter.snapshot(now),
			"progression": {"level": player.level, "experience": player.experience, "next": player.level_xp_to_next()}})

@rpc("authority", "call_remote", "reliable", 0)
func receive_state(snapshot: Dictionary) -> void:
	if GameMode.is_world_server(): return
	state = snapshot
	state_changed.emit(snapshot)
	for peer_id: int in snapshot.levels:
		var player: SpikePlayer3D = _world.characters.get(peer_id)
		if player != null: player.set_level(int(snapshot.levels[peer_id]))
	if _world.metin_encounter != null and not snapshot.get("metin",{}).is_empty(): _world.metin_encounter.receive_snapshot(snapshot.metin)
	_world.mob_system.apply_snapshot(snapshot.mobs)
	for peer_id: int in snapshot.health:
		var body: SpikePlayer3D = _world.characters.get(peer_id)
		if body != null:
			body.hp = int(snapshot.health[peer_id])
			body.set_alive(body.hp > 0)
			var lock: Array = snapshot.hit_locks.get(peer_id,[0,0])
			body.present_hit_lock(int(lock[0]),int(lock[1]))
	client_combat.snapshot_changed(snapshot)
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
	refresh_hud()

func refresh_hud() -> void:
	if _hud == null: return
	var hp: int = int(state.get("health", {}).get(_world.local_peer, 100))
	var target: String = "Brak celu"
	var actor: Node3D = client_combat.resolve_target(client_combat.selected_target)
	if actor is MetinStone3D:
		target = "%s: %d / %d" % [_world.metin_encounter.definition.display_name,_world.metin_encounter.runtime.hp,_world.metin_encounter.definition.max_hp]
	elif actor is SpikeMob3D:
		target = "%s: %d / %d" % [actor.title, actor.hp, actor.max_hp]
	var combo: int = int(state.get("combos", {}).get(_world.local_peer, 0))
	var options: Dictionary = state.get("combo_options",{"enabled":false,"skill_level":0,"length":4})
	var status: String = "Odrodzenie za %.1f s" % float(state.get("respawns", {}).get(_world.local_peer, 0)) if hp == 0 else _notice
	_hud.text = "HP: %d / 100 · Combo: %d / %d (%s, Lv%d)\nSpacja — combo · C — Combo ON/OFF · E — łup\nLPM — cel · F — autoatak (%s)\n%s · %s" % [hp, combo, int(options.length), "ON" if options.enabled else "OFF", int(options.skill_level), "wł." if client_combat.autoattack else "wył.", target, status]
	var progression: Dictionary = state.get("progression", {"level": 1, "experience": 0, "next": PlayerResource.LEVEL_XP_BASE})
	_experience_label.text = "Poziom %d · XP: %d / %d%s" % [int(progression.level), int(progression.experience), int(progression.next), "\n" + _xp_notice if _xp_notice != "" else ""]
	_experience_bar.max_value = int(progression.next)
	_experience_bar.value = int(progression.experience)

func publish_swing(peer_id: int, resolved: Dictionary) -> void:
	for observer: int in _world.characters:
		receive_swing.rpc_id(observer,peer_id,resolved.animation_key,resolved.step_index,int(resolved.timing.motion),resolved.finisher,resolved.ratio,resolved.action_id,resolved.yaw,int(resolved.timing.preinput))

func publish_hits(peer_id: int, results: Array[Dictionary], swing: Dictionary) -> void:
	for observer: int in _world.characters:
		receive_hits.rpc_id(observer,peer_id,results,int(swing.get("action_id",0)),int(swing.get("step_index",maxi(1,attacks.attack_runtime(peer_id).display_combo_step)-1)),bool(swing.get("finisher",false)))

func assist_direction(manual: Vector2) -> Vector2:
	return client_combat.assist_direction(manual)

func cancel_autoattack() -> void:
	client_combat.autoattack = false

func set_notice(message: String) -> void:
	_notice = message
	refresh_hud()

func publish_swing_presentation(peer_id: int, animation_key: StringName, step_index: int) -> void:
	swing_received.emit(peer_id,animation_key,step_index)

func publish_confirmed_hit(event: Dictionary) -> void:
	confirmed_hit_received.emit(event)

func _process(delta: float) -> void:
	if not GameMode.is_client(): return
	if _xp_notice != "" and Time.get_ticks_msec() >= _xp_notice_until_ms:
		_xp_notice = ""
		refresh_hud()
	_world.mob_system.interpolate(delta)
	client_combat.process(delta)

func _unhandled_input(event: InputEvent) -> void:
	client_combat.handle_input(event)
	if not GameMode.is_client() or not _world.input_enabled or ClientState.menu_open: return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		if not _world.characters.has(_world.local_peer): return
		var nearest: float = INF
		var selected: String = ""
		for uid: String in state.get("drops",{}):
			var distance: float = _world.characters[_world.local_peer].position.distance_to(state.drops[uid].position)
			if distance < nearest:
				nearest = distance
				selected = uid
		if selected != "": request_pickup.rpc_id(1,selected)
		get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	client_combat.dispose()

func _tick_player_lifecycle(now: int) -> void:
	# Existing player-only respawn policy; shared actor and attack service do not own it.
	for peer_id: int in _world.characters:
		var body: SpikePlayer3D = _world.characters[peer_id]
		if body.respawn_at_ms <= 0 or now < body.respawn_at_ms: continue
		body.hp = body.max_hp
		body.set_alive(true)
		body.position = _world.player_spawn()
		body.velocity = Vector3.ZERO
		_world.intentions[peer_id]["direction"] = Vector2.ZERO
		body.respawn_at_ms = 0
