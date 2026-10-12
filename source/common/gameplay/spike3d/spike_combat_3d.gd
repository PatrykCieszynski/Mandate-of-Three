class_name SpikeCombat3D
extends Node
var services: MandateWorldServices
## Facing-based melee: no target ID or hit list is accepted from a client.

const MOB_HP: int = 120
const HOME: Vector3 = Vector3(-4, 0, 0)
const AGGRO: float = 6.0
const MOB_REACH: float = 1.65
const ATTACK_REACH: float = 2.4
const HALF_ANGLE: float = 65.0
const PICKUP_REACH: float = 2.5
const PROTECTION_MS: int = 15000
const LOOT_LIFETIME_MS: int = 120000
const DOG_XP: int = 20

signal swing_received(peer_id: int, animation_key: StringName, step_index: int)
signal feedback_received(result: Dictionary)
signal state_changed(snapshot: Dictionary)
var dogs: Dictionary[int, SpikeWildDog3D] = {}
var _warned_unknown_mob_keys: Dictionary[StringName, bool] = {}
var packs: Dictionary[int, MobPackRuntime] = {}
var _next_mob_id: int = 0
var _next_pack_id: int = 0
var ground: Dictionary[String, Dictionary] = {}
var health: Dictionary[int, int] = {}
var _respawn_ms: Dictionary[int, int] = {}
var _next_attack_ms: Dictionary[int, int] = {}
var _movement_unlock_ms: Dictionary[int, int] = {}
var _combo: Dictionary[int, int] = {}
var _combo_states: Dictionary[int, BasicAttackComboState] = {}
var _pending: Dictionary[int, Dictionary] = {}
var _sequences: Dictionary[int, int] = {}
var _pickup_ms: Dictionary[int, int] = {}
var _snapshot_accum: float = 0
var _world: SpikeWorld3D
var _hud: Label
var _notice: String = ""
var _visual_drops: Dictionary[String, Node3D] = {}
var _client_sequence: int = 0
var _client_request_at: int = -1
var _client_intent_sent := false
var _client_was_active := false
var _active_attacks: Dictionary[int, Dictionary] = {}
var _queued_attacks: Dictionary[int, int] = {}
var _desired_facing: Dictionary[int, Dictionary] = {}
var _feedback: CombatFeedback3D
signal confirmed_hit_received(event: Dictionary)
var selected_target: Dictionary = {}
var autoattack: bool = false
var state: Dictionary = {}
var dev_god_mode: bool = false
var trace_debug_enabled: bool = false
var _trace_debug: Dictionary[int, CombatTraceDebug3D] = {}
var navigation_region: NavigationRegion3D
var _experience_label: Label
var _experience_bar: ProgressBar
var _xp_notice: String = ""
var _xp_notice_until_ms: int = 0

func _ready() -> void:
	_world = get_parent()
	dev_god_mode = GameMode.is_world_server() and OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-god-mode")
	trace_debug_enabled = OS.has_feature("editor") and (OS.get_cmdline_user_args().has("--combat-trace-debug") or (DisplayServer.get_name() != "headless" and FileAccess.file_exists("res://.godot/runtime/trace-debug.enabled")))
	if dev_god_mode: print("DEV_GOD_MODE enabled for local World players")
	_build_navigation() # Shared geometry also guides client NPC approach intentions.
	if GameMode.is_world_server():
		if _world.region != null:
			for point: MobSpawnPoint3D in _world.region.find_children("*","MobSpawnPoint3D",true,false):
				assert(point.valid(),"Invalid mob spawn point: " + str(point.name))
				create_pack(point.members,_world.to_local(point.global_position),point.spawn_radius,point.wander_radius,point.leash_radius,point.respawn_seconds)
		else:
			# Small legacy arena fixture; same spawning path, singleton packs.
			var entry := MobSpawnEntry.new()
			entry.mob = preload("res://source/common/gameplay/mobs/wild_dog.tres")
			for home: Vector3 in [HOME,Vector3(-2,0,-1),Vector3(-6,0,-1),Vector3(-4,0,-3)]:
				create_pack([entry],home,0,0,12,6)
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

func create_pack(members: Array[MobSpawnEntry], anchor: Vector3, spawn_radius: float, wander_radius: float, leash_radius: float, respawn_seconds: float = 15, source_metinstone_id: String = "", expires_at: int = 0) -> MobPackRuntime:
	assert(GameMode.is_world_server() and anchor.is_finite() and not members.is_empty())
	assert(spawn_radius >= 0 and wander_radius >= spawn_radius and leash_radius > wander_radius and respawn_seconds >= 0)
	# Reject the whole composition before allocating IDs or spawning any members.
	# This guard also runs in release builds where assertions are disabled.
	for entry: MobSpawnEntry in members:
		if entry == null or not entry.valid():
			push_warning("Rejected mob pack: invalid or noncanonical spawn definition")
			return null
	var pack := MobPackRuntime.new()
	_next_pack_id += 1
	pack.pack_instance_id = _next_pack_id
	pack.anchor = anchor
	pack.spawn_radius = spawn_radius
	pack.wander_radius = wander_radius
	pack.leash_radius = leash_radius
	pack.respawn_seconds = respawn_seconds
	pack.respawn_enabled = respawn_seconds > 0
	pack.source_metinstone_id = source_metinstone_id
	pack.expires_at = expires_at
	pack.rng.randomize()
	packs[pack.pack_instance_id] = pack
	for entry: MobSpawnEntry in members:
		for i: int in entry.count: spawn_mob(entry.mob,pack.random_point(spawn_radius),pack)
	return pack

func spawn_mob(definition: MobDefinition, position: Vector3, pack: MobPackRuntime) -> SpikeWildDog3D:
	if not MobDefinitions.is_registered(definition) or not definition.valid():
		push_warning("Rejected mob spawn: invalid or noncanonical definition")
		return null
	assert(GameMode.is_world_server() and packs.get(pack.pack_instance_id) == pack)
	_next_mob_id += 1
	var dog := SpikeWildDog3D.new()
	dog.name = "Mob_%d" % _next_mob_id
	dog.definition = definition
	dog.reaction_profile = definition.reaction_profile
	dog.mob_key = definition.mob_key
	dog.max_hp = definition.max_hp
	dog.attack_damage = definition.attack_damage
	dog.move_speed = definition.move_speed
	dog.visual_id = definition.visual_id
	dog.proximity_aggro = definition.proximity_aggro
	dog.title = definition.display_name
	dog.pack_instance_id = pack.pack_instance_id
	dog.source_metinstone_id = pack.source_metinstone_id
	dog.respawn_enabled = pack.respawn_enabled
	dog.expires_at = pack.expires_at
	dog.setup_dog(_next_mob_id,position)
	dog.home = pack.anchor
	dog.wander_at_ms = Time.get_ticks_msec() + pack.rng.randi_range(1000,4000)
	_world.add_child(dog)
	dogs[dog.mob_instance_id] = dog
	pack.actor_ids.append(dog.mob_instance_id)
	return dog

func aggro_pack(pack_id: int, peer_id: int) -> void:
	if not GameMode.is_world_server() or not is_player_alive(peer_id) or not packs.has(pack_id): return
	var pack: MobPackRuntime = packs[pack_id]
	if _horizontal_distance(_world.characters[peer_id].position,pack.anchor) > pack.leash_radius: return
	for id: int in pack.actor_ids:
		var dog: SpikeWildDog3D = dogs.get(id)
		if dog == null or dog.ai_state in ["DEAD","DISABLED"]: continue
		dog.target_peer = peer_id
		dog.ai_state = "CHASE"

static func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x-b.x,a.z-b.z).length()

func _remove_mob(id: int) -> void:
	var dog: SpikeWildDog3D = dogs[id]
	dog.collision_layer = 0
	var pack: MobPackRuntime = packs.get(dog.pack_instance_id)
	if pack != null: pack.actor_ids.erase(id)
	dogs.erase(id)
	dog.queue_free()

func _tick_mobs(delta: float, now: int) -> void:
	for id: int in dogs.keys():
		var dog: SpikeWildDog3D = dogs[id]
		if (dog.expires_at > 0 and now >= dog.expires_at) or (dog.ai_state == "DEAD" and now >= dog.dead_until_ms):
			_remove_mob(id)
		else: _tick_dog(dog,delta,now)
	for pack_id: int in packs.keys():
		var pack: MobPackRuntime = packs[pack_id]
		for ticket: Dictionary in pack.replacements.duplicate():
			if now < int(ticket.at): continue
			pack.replacements.erase(ticket)
			spawn_mob(ticket.definition,pack.random_point(pack.spawn_radius),pack)
		if not pack.respawn_enabled and pack.actor_ids.is_empty(): packs.erase(pack_id)

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
	return null if not services.available() or services.economy() == null else services.economy().item_store

func initialize_peer(peer_id: int) -> void:
	health[peer_id] = 100
	if OS.has_feature("editor"):
		for arg: String in OS.get_cmdline_user_args():
			if arg.begins_with("--dev-combo-skill="): set_combo_skill_level(peer_id,arg.get_slice("=",1).to_int())
	_send_snapshot()

func remove_peer(peer_id: int) -> void:
	if _trace_debug.has(peer_id):
		_trace_debug[peer_id].queue_free()
		_trace_debug.erase(peer_id)
	for collection: Dictionary in [health, _respawn_ms, _next_attack_ms, _movement_unlock_ms, _combo, _combo_states, _pending, _sequences, _pickup_ms, _active_attacks, _queued_attacks, _desired_facing]:
		collection.erase(peer_id)
	for dog: SpikeWildDog3D in dogs.values():
		if dog.target_peer == peer_id:
			dog.target_peer = 0
			if dog.ai_state not in ["DEAD", "DISABLED"]: _begin_return(dog)

func _owner(peer_id: int) -> int:
	var resource: PlayerResource = services.player_for_peer(peer_id)
	return 0 if resource == null else resource.player_id

func is_player_alive(peer_id: int) -> bool:
	return _world.characters.has(peer_id) and health.get(peer_id, 0) > 0

func can_move(peer_id: int, now: int = Time.get_ticks_msec()) -> bool:
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	return health.get(peer_id,100) > 0 and now >= _movement_unlock_ms.get(peer_id,0) and (body == null or (not body.hit_reaction.locked(now) and not body.knockback_active()))

@rpc("any_peer", "call_remote", "reliable", 1)
func request_attack(sequence: int) -> void:
	if not GameMode.is_world_server() or _store() == null: return
	var peer_id := multiplayer.get_remote_sender_id()
	if sequence < 0 or sequence > 2147483647 or sequence <= _sequences.get(peer_id,-1): return
	var now := Time.get_ticks_msec()
	if not begin_attack(peer_id,sequence,now) and is_player_alive(peer_id) and not _queued_attacks.has(peer_id):
		var body: SpikeCharacter3D = _world.characters[peer_id]
		var retry_at: int = maxi(_next_attack_ms.get(peer_id,now),body.hit_reaction.get_up_until_ms)
		var active: Dictionary = _active_attacks.get(peer_id,{})
		if not active.is_empty() and now < int(active.started)+int(active.timing.preinput): retry_at = int(active.started)+int(active.timing.preinput)
		receive_attack_wait.rpc_id(peer_id,maxi(100,retry_at-now+10))

@rpc("authority", "call_remote", "reliable", 0)
func receive_attack_wait(delay_ms: int) -> void:
	if not GameMode.is_client(): return
	_client_intent_sent = false
	_client_request_at = Time.get_ticks_msec()+delay_ms

func combo_state(peer_id: int) -> BasicAttackComboState:
	if not _combo_states.has(peer_id): _combo_states[peer_id] = BasicAttackComboState.new()
	return _combo_states[peer_id]

func set_combo_skill_level(peer_id: int, level: int) -> bool:
	if not GameMode.is_world_server() or not is_player_alive(peer_id): return false
	var accepted := combo_state(peer_id).set_skill_level(level)
	if accepted and combo_state(peer_id).current_combo_step == -1: _combo.erase(peer_id)
	return accepted

func set_combo_enabled(peer_id: int, enabled: bool) -> bool:
	if not GameMode.is_world_server() or not is_player_alive(peer_id): return false
	var accepted := combo_state(peer_id).set_enabled(enabled)
	if accepted and combo_state(peer_id).current_combo_step == -1: _combo.erase(peer_id)
	return accepted

func set_combo_weapon_mode(peer_id: int, mode: StringName) -> bool:
	if not GameMode.is_world_server() or not is_player_alive(peer_id): return false
	var accepted := combo_state(peer_id).set_weapon_mode(mode)
	if accepted and combo_state(peer_id).current_combo_step == -1: _combo.erase(peer_id)
	return accepted

@rpc("any_peer", "call_remote", "reliable", 1)
func request_combo_toggle() -> void:
	if not GameMode.is_world_server(): return
	var sender := multiplayer.get_remote_sender_id()
	if not is_player_alive(sender): return
	set_combo_enabled(sender,not combo_state(sender).combo_enabled)

func remember_next_facing(peer_id: int, direction: Vector2) -> void:
	if direction.length_squared() > .001:
		_desired_facing[peer_id] = {"yaw":atan2(-direction.x,-direction.y),"time":Time.get_ticks_msec()}

func begin_attack(peer_id: int, sequence: int, now: int) -> bool:
	if not is_player_alive(peer_id) or sequence < 0 or sequence > 2147483647 or sequence <= _sequences.get(peer_id,-1): return false
	if _owner(peer_id) <= 0: return false
	_sequences[peer_id] = sequence
	var body: SpikeCharacter3D = _world.characters[peer_id]
	if body.hit_reaction.locked(now) or body.knockback_active(): return false
	if _queued_attacks.has(peer_id): return false # At most one next intent.
	var active: Dictionary = _active_attacks.get(peer_id,{})
	var chained := false
	if not active.is_empty():
		var elapsed := now-int(active.started)
		var timing: Dictionary = active.timing
		if elapsed < int(timing.preinput): return false
		# Finishers start a new chain at their end; malformed native final input
		# windows (04 Direct > Limit) are never treated as an early chain link.
		var restart: bool = active.finisher or elapsed > int(timing.limit)
		if now < _next_attack_ms.get(peer_id,0):
			active["restart_queued"] = restart
			_queued_attacks[peer_id] = sequence
			return true
		if restart: combo_state(peer_id).reset()
		chained = not restart
	return _start_attack(peer_id,sequence,now,chained)

func _start_attack(peer_id: int, sequence: int, now: int, chained: bool = false) -> bool:
	var attack := services.runtime_attack(_owner(peer_id))
	var ratio := services.runtime_attack_speed_ratio(_owner(peer_id))
	if attack < 0 or ratio <= 0: return false
	var resolved := combo_state(peer_id).take_step(now,chained)
	if resolved.is_empty(): return false
	var hit: BasicAttackStepDefinition = resolved.step
	if OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-legacy-melee"): hit.combat_trace = null
	var body: SpikeCharacter3D = _world.characters[peer_id]
	var facing: Dictionary = _desired_facing.get(peer_id,{})
	if not facing.is_empty() and (now-int(facing.time) <= 500 or (_active_attacks.has(peer_id) and int(facing.time) >= int(_active_attacks[peer_id].started))): body.rotation.y = facing.yaw
	_desired_facing.erase(peer_id)
	var timing := hit.scaled_timing(ratio)
	_combo[peer_id] = int(resolved.step_index)+1
	var next_delay: int = timing.end if resolved.finisher else timing.direct
	_next_attack_ms[peer_id] = now+next_delay
	_movement_unlock_ms[peer_id] = now+int(timing.motion)
	body.start_attack_advance(body.rotation.y,hit.advance_distance,int(timing.motion)/1000.0)
	resolved.merge({"yaw":body.rotation.y,"impact":now+int(timing.impact),"started":now,"hit_set":{},
		"attack":attack,"ratio":ratio,"timing":timing,"action_id":sequence})
	_pending[peer_id] = resolved
	_active_attacks[peer_id] = resolved
	for observer: int in _world.characters:
		receive_swing.rpc_id(observer,peer_id,resolved.animation_key,resolved.step_index,int(timing.motion),resolved.finisher,
			ratio,sequence,body.rotation.y,int(timing.preinput))
	return true

func _advance_attack_queue(now: int) -> void:
	for peer_id: int in _active_attacks.keys():
		var active: Dictionary = _active_attacks[peer_id]
		var body: SpikeCharacter3D = _world.characters.get(peer_id)
		if not is_player_alive(peer_id) or body == null or body.hit_reaction.locked(now) or body.knockback_active():
			_clear_attack_intents(peer_id)
			continue
		if now < _next_attack_ms.get(peer_id,0): continue
		if _queued_attacks.has(peer_id):
			var sequence: int = _queued_attacks[peer_id]
			_queued_attacks.erase(peer_id)
			if active.get("restart_queued",false): combo_state(peer_id).reset()
			_start_attack(peer_id,sequence,now,not active.get("restart_queued",false))
		elif now > int(active.started)+maxi(int(active.timing.motion),int(active.timing.limit)):
			combo_state(peer_id).reset()
			_active_attacks.erase(peer_id)

func _clear_attack_intents(peer_id: int) -> void:
	_movement_unlock_ms.erase(peer_id)
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null: body.cancel_attack_advance()
	_pending.erase(peer_id)
	_active_attacks.erase(peer_id)
	_queued_attacks.erase(peer_id)
	_desired_facing.erase(peer_id)


func resolve_swing(peer_id: int, swing: Dictionary, now: int) -> Array[int]:
	var hit_ids: Array[int] = []
	if not is_player_alive(peer_id) or _world.characters[peer_id].hit_reaction.locked(now): return hit_ids
	var definition: BasicAttackStepDefinition = swing.step
	if swing.get("resolved",false) or now < int(swing.get("impact",now)): return hit_ids
	var traced := definition.combat_trace != null
	if traced:
		if definition.impact_ms < definition.hit_start_ms or definition.impact_ms > definition.hit_end_ms: return hit_ids
	swing["resolved"] = true # One scheduled resolution; never repeat damage from this swing.
	var hit_set: Dictionary = swing.get("hit_set",{})
	swing["hit_set"] = hit_set
	var measured_at := Time.get_ticks_usec()
	var trace_tests := 0
	var results: Array[Dictionary] = []
	var body: SpikeCharacter3D = _world.characters[peer_id]
	var yaw: float = swing.yaw
	var forward := Vector3(-sin(yaw), 0, -cos(yaw))
	var actor := Transform3D(Basis(Vector3.UP,yaw),body.global_position)
	var candidates: Array[Dictionary]
	if traced: candidates = CombatTraceResolver.candidates(_world.get_world_3d().direct_space_state,definition.combat_trace,actor)
	else: candidates = _legacy_candidates(body)
	for hit: Dictionary in candidates:
		if hit.collider is MetinStone3D:
			var metin: MetinEncounter = _world.metin_encounter
			if hit_set.has(-1): continue
			trace_tests += 1
			if metin.active() and _melee_hits(definition,actor,metin.stone,forward) and _world.has_line_of_sight(body.position,metin.stone.position):
				var previous_hp: int = metin.runtime.hp
				if metin.apply_damage(peer_id,int(swing.attack*definition.damage_multiplier),now):
					hit_set[-1] = true
					hit_ids.append(-1) # Stone is immovable and has no actor action lock.
					results.append({"id":-1,"damage":previous_hp-metin.runtime.hp,"reaction":HitReaction.Type.NONE,"duration":0.0,"get_up_duration":0.0,"target_kind":"metin","target_id":metin.runtime.stone_instance_id})
			continue
		var dog: SpikeWildDog3D = hit.collider as SpikeWildDog3D
		if dog == null or hit_set.has(dog.mob_id) or dog.ai_state in ["DEAD", "RETURN", "DISABLED"]: continue
		var offset: Vector3 = dog.position - body.position
		var horizontal := Vector3(offset.x, 0, offset.z)
		trace_tests += 1
		if not _melee_hits(definition,actor,dog,forward): continue
		if not _world.has_line_of_sight(body.position, dog.position): continue
		var result := HitReactionResolver.resolve(definition,dog.reaction_profile,int(swing.attack),dog.hp,dog.hit_reaction.locked(now))
		var damage: int = result.damage
		if damage <= 0: continue
		hit_set[dog.mob_id] = true
		hit_ids.append(dog.mob_id)
		aggro_pack(dog.pack_instance_id,peer_id)
		dog.hp -= damage
		var owner_id: int = _owner(peer_id)
		dog.contributions[owner_id] = dog.contributions.get(owner_id, 0) + damage
		dog.contribution_players[owner_id] = services.player_for_peer(peer_id)
		if dog.hp == 0:
			_die(dog, now)
		else:
			dog.hit_reaction.apply(result,now)
			dog.apply_knockback(horizontal if horizontal.length_squared() > 0.001 else forward,result.knockback_distance)
		var event := result.presentation()
		event["id"] = dog.mob_instance_id
		event["target_kind"] = "mob"
		event["target_id"] = dog.mob_instance_id
		results.append(event)
	for observer: int in _world.characters:
		receive_hits.rpc_id(observer, peer_id, results,int(swing.get("action_id",0)),int(swing.get("step_index",_combo.get(peer_id,1)-1)),bool(swing.get("finisher",false)))
	if OS.has_feature("editor") and OS.get_cmdline_user_args().has("--combat-trace-metrics"):
		print("COMBAT_TRACE_METRICS path=", "trace" if traced else "legacy", " candidates=",candidates.size()," tests=",trace_tests," hits=",hit_ids.size()," usec=",Time.get_ticks_usec()-measured_at)
	return hit_ids

func _legacy_candidates(body: SpikeCharacter3D) -> Array[Dictionary]:
	var shape := SphereShape3D.new()
	shape.radius = ATTACK_REACH+0.4
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY,body.global_position+Vector3.UP*0.5)
	query.collision_mask = 4
	return _world.get_world_3d().direct_space_state.intersect_shape(query,CombatTraceResolver.MAX_CANDIDATES)

func _melee_hits(step: BasicAttackStepDefinition, actor: Transform3D, target: Node3D, forward: Vector3) -> bool:
	if step.combat_trace != null:
		return CombatTraceResolver.hits_capsule(step.combat_trace,actor,target.global_position,target.combat_radius(),target.combat_height(),target.combat_bottom_offset())
	var offset := target.global_position-actor.origin
	var horizontal := Vector3(offset.x,0,offset.z)
	return horizontal.length() <= ATTACK_REACH and absf(offset.y) <= 1.2 and (horizontal.length_squared() < 0.001 or horizontal.normalized().dot(forward) >= cos(deg_to_rad(HALF_ANGLE)))

func _die(dog: SpikeWildDog3D, now: int) -> void:
	if dog.ai_state == "DEAD": return
	dog.die(now)
	var pack: MobPackRuntime = packs.get(dog.pack_instance_id)
	if dog.respawn_enabled and pack != null:
		pack.replacements.append({"definition":dog.definition,"at":now+int(pack.respawn_seconds*1000)})
	var owner_id: int = 0
	var highest: int = -1
	for contributor: int in dog.contributions:
		if dog.contributions[contributor] > highest or (dog.contributions[contributor] == highest and contributor < owner_id):
			owner_id = contributor
			highest = dog.contributions[contributor]
	drop_reward(dog.position,owner_id,now)
	if owner_id > 0: _award_experience(dog.contribution_players.get(owner_id))
	dog.contribution_players.clear()

func drop_reward(position: Vector3, owner_id: int, now: int, yang: int = SpikeCurrency3D.DOG_YANG) -> void:
	var owner_name: String = ""
	for peer_id: int in _world.characters:
		if _owner(peer_id) == owner_id: owner_name = services.player_for_peer(peer_id).display_name
	var uid: String = Crypto.new().generate_random_bytes(16).hex_encode()
	ground[uid] = {"position":position,"definition_id":"iron_sword","bonus":randi_range(1,9),
		"owner":owner_id,"owner_name":owner_name,"protected_until":now+PROTECTION_MS,"expires":now+LOOT_LIFETIME_MS}
	_world.currency_endpoint.spawn_currency(position,owner_id,owner_name,now,yang)

func _award_experience(resource: PlayerResource) -> void:
	if resource == null: return
	# A contributor may have disconnected/relogged before the killing blow.
	# Always use the current in-process resource rather than an old encounter ref.
	resource = services.economy().dirty_progression.get(resource.player_id, resource)
	for current: PlayerResource in services.players():
		if current.player_id == resource.player_id:
			resource = current
			break
	var result: Dictionary = resource.add_experience(DOG_XP)
	services.economy().mark_progression_dirty(resource)
	for peer_id: int in services.peers():
		if services.player_for_peer(peer_id) != resource: continue
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
func receive_swing(peer_id: int, animation_key: StringName, step_index: int, motion_ms: int, finisher: bool, ratio: float = 1.0, action_id: int = 0, yaw: float = 0.0, preinput_ms: int = 0) -> void:
	if not GameMode.is_client(): return
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null:
		body.accept_swing_facing(yaw)
		body.play_swing(animation_key,motion_ms,finisher,ratio)
	if peer_id == _world.local_peer:
		_client_intent_sent = false
		_client_request_at = Time.get_ticks_msec()+preinput_ms+10
	if trace_debug_enabled and body != null:
		var step: BasicAttackStepDefinition
		for combo: BasicAttackComboDefinition in [BasicAttackCombos.BASE,BasicAttackCombos.COMBO_5,BasicAttackCombos.COMBO_6]:
			for candidate: BasicAttackStepDefinition in combo.steps:
				if candidate.animation_key == animation_key: step = candidate
		if step != null:
			if _trace_debug.has(peer_id): _trace_debug[peer_id].queue_free()
			var overlay := CombatTraceDebug3D.new()
			_world.add_child(overlay)
			overlay.global_transform = Transform3D(Basis(Vector3.UP,body.rotation.y),body.global_position)
			var targets: Array[Dictionary] = []
			for dog: SpikeWildDog3D in dogs.values():
				targets.append({"id":dog.mob_id,"position":overlay.to_local(dog.global_position),"radius":dog.combat_radius(),"height":dog.combat_height(),"bottom_offset":dog.combat_bottom_offset()})
			overlay.configure(step,targets,OS.get_cmdline_user_args().has("--dev-legacy-melee"))
			_trace_debug[peer_id] = overlay
	swing_received.emit(peer_id,animation_key,step_index)

@rpc("authority", "call_remote", "reliable", 0)
func receive_hits(peer_id: int, results: Array[Dictionary], action_id: int = 0, step_index: int = 0, finisher: bool = false) -> void:
	if not GameMode.is_client(): return
	if _trace_debug.has(peer_id): _trace_debug[peer_id].mark_hits(results)
	if _feedback == null:
		_feedback = CombatFeedback3D.new()
		_world.add_child(_feedback)
	for result: Dictionary in results:
		var target: Node3D = dogs.get(int(result.id))
		if int(result.id) == -1 and _world.metin_encounter != null:
			if str(result.get("target_id","")) == _world.metin_encounter.runtime.stone_instance_id: target = _world.metin_encounter.stone
		var event := result.duplicate()
		event.merge({"attacker":peer_id,"action_id":action_id,"step_index":step_index,"finisher":finisher})
		if target != null and _feedback.confirm(event,target,peer_id == _world.local_peer):
			confirmed_hit_received.emit(event)
			if _world.camera_controller != null: _world.camera_controller.confirm_finisher(event,peer_id == _world.local_peer)
		var body: SpikeWildDog3D = dogs.get(int(result.id))
		if body != null: _present_reaction(body,result)
	if peer_id == _world.local_peer:
		_notice = "Trafiono: %d" % results.size()
		_refresh_hud()

func _present_reaction(body: SpikeCharacter3D, result: Dictionary) -> void:
	match int(result.reaction):
		HitReaction.Type.FLINCH, HitReaction.Type.KNOCKBACK: body.play_hit()
		HitReaction.Type.KNOCKDOWN:
			body.present_hit_lock(int(float(result.duration)*1000),int(float(result.get_up_duration)*1000))

@rpc("any_peer", "call_remote", "reliable", 1)
func request_pickup(uid: String) -> void:
	if not GameMode.is_world_server() or _store() == null:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not is_player_alive(peer_id): return
	var now: int = Time.get_ticks_msec()
	if now - _pickup_ms.get(peer_id, -1000) < 100:
		_reply(peer_id, {"ok": false, "error": "too_fast"})
		return
	_pickup_ms[peer_id] = now
	var result: Dictionary = pickup_for_peer(peer_id, uid, now)
	if result.ok: _world.inventory_endpoint.refresh_authoritative_state(peer_id)
	_reply(peer_id, result)
	if result.ok:
		_world.inventory_endpoint.inventory_changed.emit(_owner(peer_id))
		_send_snapshot()

func pickup_for_peer(peer_id: int, uid: String, now: int) -> Dictionary:
	# Synchronous: another RPC cannot interleave between commit and ground erase.
	if not ItemInstance.valid_uid(uid) or not ground.has(uid):
		return {"ok": false, "error": "gone"}
	var drop: Dictionary = ground[uid]
	if now >= int(drop.expires):
		ground.erase(uid)
		return {"ok": false, "error": "gone"}
	var owner_id: int = _owner(peer_id)
	if now < int(drop.protected_until) and owner_id != int(drop.owner):
		return {"ok": false, "error": "reserved"}
	var body: SpikeCharacter3D = _world.characters[peer_id]
	if body.position.distance_to(drop.position) > PICKUP_REACH or not _world.has_line_of_sight(body.position, drop.position):
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
			_world.characters[peer_id].set_alive(true)
			var body: SpikeCharacter3D = _world.characters[peer_id]
			body.position = _world.player_spawn()
			body.velocity = Vector3.ZERO
			_world.intentions[peer_id]["direction"] = Vector2.ZERO
			_respawn_ms.erase(peer_id)
	for peer_id: int in _pending.keys():
		if now >= int(_pending[peer_id].impact):
			var swing: Dictionary = _pending[peer_id]
			_pending.erase(peer_id)
			resolve_swing(peer_id, swing, now)
	_tick_mobs(delta,now)
	_advance_attack_queue(now)
	if _world.metin_encounter != null: _world.metin_encounter.tick(now)
	_snapshot_accum += delta
	if _snapshot_accum >= 0.1:
		_snapshot_accum = fmod(_snapshot_accum, 0.1)
		_send_snapshot()

func hurt_player(peer_id: int, damage: int, now: int, hit: AttackHitDefinition = BasicAttackHits.MOB_MELEE, hit_direction: Vector3 = Vector3.ZERO) -> CombatHitResult:
	if not is_player_alive(peer_id): return null
	if dev_god_mode: return CombatHitResult.new() # No damage, action lock or impulse.
	var body: SpikeCharacter3D = _world.characters[peer_id]
	var result := HitReactionResolver.resolve(hit,body.reaction_profile,damage,int(health[peer_id]),body.hit_reaction.locked(now))
	health[peer_id] -= result.damage
	body.hit_reaction.apply(result,now)
	body.apply_knockback(hit_direction,result.knockback_distance)
	if result.interrupts_attack:
		_clear_attack_intents(peer_id)
		_combo.erase(peer_id)
		combo_state(peer_id).reset()
	for observer: int in _world.characters: receive_hurt.rpc_id(observer,peer_id,result.presentation())
	if health[peer_id] == 0:
		body.set_alive(false)
		body.hit_reaction.clear()
		body.knockback_velocity = Vector3.ZERO
		_respawn_ms[peer_id] = now + 2000
		_clear_attack_intents(peer_id)
		_combo.erase(peer_id)
		combo_state(peer_id).reset()
		_next_attack_ms.erase(peer_id)
		_world.intentions[peer_id]["direction"] = Vector2.ZERO
		_send_snapshot()
	return result

@rpc("authority", "call_remote", "reliable", 0)
func receive_hurt(peer_id: int, result: Dictionary) -> void:
	if not GameMode.is_client(): return
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null: _present_reaction(body,result)
	if peer_id == _world.local_peer and (int(result.reaction) == HitReaction.Type.KNOCKDOWN or (body != null and not body.alive)):
		_client_intent_sent = false
		_client_request_at = Time.get_ticks_msec()+int((float(result.duration)+float(result.get_up_duration))*1000)+100

func _begin_return(dog: SpikeWildDog3D) -> void:
	var pack: MobPackRuntime = packs.get(dog.pack_instance_id)
	dog.return_target = pack.random_point(pack.wander_radius) if pack != null else dog.home
	dog.ai_state = "RETURN"
	dog.target_peer = 0

func _tick_dog(dog: SpikeWildDog3D, delta: float, now: int) -> void:
	if dog.ai_state in ["DEAD","DISABLED"]: return
	var pack: MobPackRuntime = packs.get(dog.pack_instance_id)
	if pack == null: return
	if dog.hit_reaction.locked(now) or dog.knockback_active():
		dog.move_dog(delta,Vector2.ZERO,now)
		return
	if not dog.ai_enabled: return
	if dog.proximity_aggro and dog.ai_state in ["IDLE","WANDER"]:
		var nearest: float = AGGRO
		var target: int = 0
		for peer_id: int in _world.characters:
			var distance := _horizontal_distance(dog.position,_world.characters[peer_id].position)
			if is_player_alive(peer_id) and distance < nearest and _horizontal_distance(_world.characters[peer_id].position,pack.anchor) <= pack.leash_radius:
				target = peer_id
				nearest = distance
		if target != 0: aggro_pack(pack.pack_instance_id,target)
	if dog.ai_state in ["CHASE","ATTACK"]:
		if not is_player_alive(dog.target_peer) or _horizontal_distance(dog.position,pack.anchor) > pack.leash_radius or _horizontal_distance(_world.characters[dog.target_peer].position,pack.anchor) > pack.leash_radius:
			_begin_return(dog)
	var direction := Vector2.ZERO
	if dog.ai_state in ["CHASE","ATTACK"]:
		var body: SpikeCharacter3D = _world.characters[dog.target_peer]
		var offset: Vector3 = body.position - dog.position
		if _horizontal_distance(dog.position,body.position) > MOB_REACH or absf(offset.y) > 1.2 or not _world.has_line_of_sight(dog.position,body.position):
			dog.ai_state = "CHASE"
			direction = Vector2(offset.x,offset.z).normalized()
		else:
			dog.ai_state = "ATTACK"
			dog.rotation.y = atan2(-offset.x,-offset.z)
			if now >= dog.stunned_until_ms and now - dog.last_attack_ms >= 1200:
				dog.last_attack_ms = now
				hurt_player(dog.target_peer,dog.attack_damage,now,BasicAttackHits.MOB_MELEE,offset)
	elif dog.ai_state == "RETURN":
		if _horizontal_distance(dog.position,dog.return_target) < 0.4:
			dog.hp = dog.max_hp
			dog.contributions.clear()
			dog.contribution_players.clear()
			dog.target_peer = 0
			dog.ai_state = "IDLE"
			dog.knockback_velocity = Vector3.ZERO
			dog.wander_at_ms = now + pack.rng.randi_range(1000,4000)
		else:
			direction = Vector2(dog.return_target.x-dog.position.x,dog.return_target.z-dog.position.z).normalized()
	elif dog.ai_state == "IDLE" and pack.wander_radius > 0 and now >= dog.wander_at_ms:
		dog.wander_target = pack.random_point(pack.wander_radius)
		dog.ai_state = "WANDER"
	elif dog.ai_state == "WANDER":
		if _horizontal_distance(dog.position,dog.wander_target) < 0.4:
			dog.ai_state = "IDLE"
			dog.wander_at_ms = now + pack.rng.randi_range(2000,5000)
		else:
			direction = Vector2(dog.wander_target.x-dog.position.x,dog.wander_target.z-dog.position.z).normalized()
	dog.move_dog(delta,direction,now)

func _mob_snapshots(now: int = Time.get_ticks_msec()) -> Array:
	var records: Array = []
	for mob: SpikeWildDog3D in dogs.values(): records.append(MobSnapshot.capture(mob,now))
	return records

func _receive_mob_snapshots(records: Array) -> void:
	var present: Dictionary[int, bool] = {}
	for record: Array in records:
		var id: int = record[MobSnapshot.Field.ID]
		var key := StringName(record[MobSnapshot.Field.MOB_KEY])
		var definition := MobDefinitions.resolve(key)
		if definition == null:
			if not _warned_unknown_mob_keys.has(key):
				_warned_unknown_mob_keys[key] = true
				push_warning("Unknown replicated mob definition: %s" % key)
			continue
		present[id] = true
		if not dogs.has(id):
			var mob := SpikeWildDog3D.new()
			mob.name = "Mob_%d" % id
			mob.definition = definition
			mob.mob_key = definition.mob_key
			mob.max_hp = definition.max_hp
			mob.title = definition.display_name
			mob.visual_id = definition.visual_id
			mob.source_metinstone_id = record[MobSnapshot.Field.SOURCE_METIN]
			mob.setup_dog(id, record[MobSnapshot.Field.POSITION])
			_world.add_child(mob)
			dogs[id] = mob
		dogs[id].present_snapshot(record)
	# An empty full snapshot removes all actors just like any other snapshot.
	for id: int in dogs.keys():
		if not present.has(id):
			dogs[id].queue_free()
			dogs.erase(id)

func _send_snapshot() -> void:
	if _store() == null: return
	var now: int = Time.get_ticks_msec()
	var mob_snapshots: Array = _mob_snapshots(now)
	var respawns: Dictionary = {}
	var levels: Dictionary = {}
	var hit_locks: Dictionary = {}
	for id: int in _world.characters:
		levels[id] = services.player_for_peer(id).level
		hit_locks[id] = _world.characters[id].hit_reaction.snapshot(now)
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
		var player: PlayerResource = services.player_for_peer(peer_id)
		receive_state.rpc_id(peer_id, {"mobs": mob_snapshots, "health": health.duplicate(), "drops": drops,
			"combo_options":{"enabled":combo_state(peer_id).combo_enabled,"skill_level":combo_state(peer_id).combo_skill_level,"length":combo_state(peer_id).definition().steps.size()},
			"combos": _combo.duplicate(), "respawns": respawns, "levels": levels, "hit_locks":hit_locks,
			"metin": {} if _world.metin_encounter == null else _world.metin_encounter.snapshot(now),
			"progression": {"level": player.level, "experience": player.experience, "next": player.level_xp_to_next()}})

@rpc("authority", "call_remote", "reliable", 0)
func receive_state(snapshot: Dictionary) -> void:
	if GameMode.is_world_server(): return
	for peer_id: int in _trace_debug.keys():
		if not snapshot.health.has(peer_id):
			_trace_debug[peer_id].queue_free()
			_trace_debug.erase(peer_id)
	state = snapshot
	state_changed.emit(snapshot)
	for peer_id: int in snapshot.levels:
		var player: SpikeCharacter3D = _world.characters.get(peer_id)
		if player != null: player.set_level(int(snapshot.levels[peer_id]))
	if _world.metin_encounter != null and not snapshot.get("metin",{}).is_empty(): _world.metin_encounter.receive_snapshot(snapshot.metin)
	_receive_mob_snapshots(snapshot.mobs)
	for peer_id: int in snapshot.health:
		var body: SpikeCharacter3D = _world.characters.get(peer_id)
		if body != null:
			body.set_alive(int(snapshot.health[peer_id]) > 0)
			var lock: Array = snapshot.hit_locks.get(peer_id,[0,0])
			body.present_hit_lock(int(lock[0]),int(lock[1]))
	_clear_invalid_target()
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
	var actor: Node3D = _resolve_target(selected_target)
	if actor is MetinStone3D:
		target = "%s: %d / %d" % [_world.metin_encounter.definition.display_name,_world.metin_encounter.runtime.hp,_world.metin_encounter.definition.max_hp]
	elif actor is SpikeWildDog3D:
		target = "%s: %d / %d" % [actor.title, actor.hp, actor.max_hp]
	var combo: int = int(state.get("combos", {}).get(_world.local_peer, 0))
	var options: Dictionary = state.get("combo_options",{"enabled":false,"skill_level":0,"length":4})
	var status: String = "Odrodzenie za %.1f s" % float(state.get("respawns", {}).get(_world.local_peer, 0)) if hp == 0 else _notice
	_hud.text = "HP: %d / 100 · Combo: %d / %d (%s, Lv%d)\nSpacja — combo · C — Combo ON/OFF · E — łup\nLPM — cel · F — autoatak (%s)\n%s · %s" % [hp, combo, int(options.length), "ON" if options.enabled else "OFF", int(options.skill_level), "wł." if autoattack else "wył.", target, status]
	var progression: Dictionary = state.get("progression", {"level": 1, "experience": 0, "next": PlayerResource.LEVEL_XP_BASE})
	_experience_label.text = "Poziom %d · XP: %d / %d%s" % [int(progression.level), int(progression.experience), int(progression.next), "\n" + _xp_notice if _xp_notice != "" else ""]
	_experience_bar.max_value = int(progression.next)
	_experience_bar.value = int(progression.experience)

func _resolve_target(target: Dictionary) -> Node3D:
	if target.is_empty(): return null
	match target.get("kind"):
		&"mob":
			var dog: SpikeWildDog3D = dogs.get(int(target.get("id",0)))
			if not is_instance_valid(dog) or dog.is_queued_for_deletion() or dog.hp <= 0 or dog.ai_state in ["DEAD","DISABLED"]: return null
			return dog
		&"metin":
			var encounter: MetinEncounter = _world.metin_encounter
			if not is_instance_valid(encounter) or not encounter.active() or encounter.runtime.hp <= 0 or encounter.runtime.stone_instance_id != str(target.get("id","")): return null
			return encounter.stone if is_instance_valid(encounter.stone) and not encounter.stone.is_queued_for_deletion() else null
	return null

func _clear_invalid_target() -> void:
	if _resolve_target(selected_target) == null and (not selected_target.is_empty() or autoattack):
		select_target({})

func select_target(target: Dictionary) -> void:
	if not target.is_empty(): _world.cancel_npc_approach()
	selected_target = target.duplicate()
	if _resolve_target(selected_target) == null: selected_target = {}
	for dog: SpikeWildDog3D in dogs.values():
		if is_instance_valid(dog) and not dog.is_queued_for_deletion():
			dog.mark_selected(selected_target.get("kind") == &"mob" and dog.mob_id == int(selected_target.get("id",0)))
	if selected_target.is_empty(): autoattack = false
	_refresh_hud()

func _unhandled_input(event: InputEvent) -> void:
	if not GameMode.is_client() or not _world.input_enabled or ClientState.menu_open: return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var camera: Camera3D = _world.gameplay_camera()
		var origin: Vector3 = camera.project_ray_origin(event.position)
		var ray := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(event.position) * 100, 4)
		var hit: Dictionary = _world.get_world_3d().direct_space_state.intersect_ray(ray)
		var dog: SpikeWildDog3D = hit.get("collider") as SpikeWildDog3D
		if hit.get("collider") is MetinStone3D and _world.metin_encounter != null:
			select_target({"kind":&"metin","id":_world.metin_encounter.runtime.stone_instance_id})
		elif dog != null:
			select_target({"kind":&"mob","id":dog.mob_id})
		else:
			select_target({})
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F8 and OS.has_feature("editor"):
			trace_debug_enabled = not trace_debug_enabled
			if not trace_debug_enabled:
				for overlay: CombatTraceDebug3D in _trace_debug.values(): overlay.queue_free()
				_trace_debug.clear()
			_notice = "Combat trace debug: " + ("ON" if trace_debug_enabled else "OFF")
			_refresh_hud()
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_C:
			request_combo_toggle.rpc_id(1)
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_F:
			_clear_invalid_target()
			autoattack = not autoattack and not selected_target.is_empty()
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
	_clear_invalid_target()
	if manual.length_squared() > 0.001:
		autoattack = false
		return manual
	if not autoattack or not _world.characters.has(_world.local_peer): return manual
	var actor: Node3D = _resolve_target(selected_target)
	if actor == null:
		autoattack = false
		return Vector2.ZERO
	var body: SpikeCharacter3D = _world.characters[_world.local_peer]
	var offset: Vector3 = actor.position - body.position
	var direction := Vector2(offset.x, offset.z).normalized()
	if Vector2(offset.x, offset.z).length() > 1.7: return direction
	var forward := Vector2(-sin(body.rotation.y), -cos(body.rotation.y))
	return direction * 0.05 if forward.dot(direction) < 0.98 else Vector2.ZERO

func _process(delta: float) -> void:
	if not GameMode.is_client(): return
	_clear_invalid_target()
	if _xp_notice != "" and Time.get_ticks_msec() >= _xp_notice_until_ms:
		_xp_notice = ""
		_refresh_hud()
	for dog: SpikeWildDog3D in dogs.values(): dog.interpolate(delta)
	if not _world.input_enabled or ClientState.menu_open or not DisplayServer.window_is_focused(): return
	var active: bool = Input.is_physical_key_pressed(KEY_SPACE)
	if autoattack and _world.characters.has(_world.local_peer):
		var actor: Node3D = _resolve_target(selected_target)
		active = actor != null and _world.characters[_world.local_peer].position.distance_to(actor.position) <= ATTACK_REACH
	active = active and _world.characters.has(_world.local_peer) and _world.characters[_world.local_peer].alive
	if active and not _client_was_active and _client_request_at < 0: _client_intent_sent = false
	if active and not _client_intent_sent and Time.get_ticks_msec() >= _client_request_at:
		_client_intent_sent = true
		_client_request_at = -1
		_client_sequence += 1
		request_attack.rpc_id(1,_client_sequence)
	if not active:
		_client_intent_sent = false
	_client_was_active = active
