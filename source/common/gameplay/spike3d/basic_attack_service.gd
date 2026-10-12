class_name BasicAttackService
extends RefCounted
## Existing basic attack orchestration; resolvers and actor policy stay separate.
const ATTACK_REACH: float = 2.4
const HALF_ANGLE: float = 65.0
var services: MandateWorldServices
var _world: SpikeWorld3D
var _endpoint: Node
var _attack_runtimes: Dictionary[int, PlayerCombatRuntime] = {}
var _attack_order: int = 0

func setup(world: SpikeWorld3D, endpoint: Node, adapter: MandateWorldServices) -> void:
	_world = world
	_endpoint = endpoint
	services = adapter

func attack_runtime(peer_id: int) -> PlayerCombatRuntime:
	if not _attack_runtimes.has(peer_id): _attack_runtimes[peer_id] = PlayerCombatRuntime.new()
	return _attack_runtimes[peer_id]

func ordered_peers(pending: bool) -> Array:
	# Preserve original map insertion order when simultaneous hits/queues compete.
	var peers: Array = _attack_runtimes.keys().filter(func(id: int) -> bool:
		return not attack_runtime(id).pending_impact.is_empty() if pending else not attack_runtime(id).active_action.is_empty())
	peers.sort_custom(func(a: int, b: int) -> bool:
		return attack_runtime(a).pending_order < attack_runtime(b).pending_order if pending else attack_runtime(a).active_order < attack_runtime(b).active_order)
	return peers

func combo_state(peer_id: int) -> BasicAttackComboState:
	return attack_runtime(peer_id).combo

func set_combo_skill_level(peer_id: int, level: int) -> bool:
	if not GameMode.is_world_server() or not _endpoint.is_player_alive(peer_id): return false
	var accepted := combo_state(peer_id).set_skill_level(level)
	if accepted and combo_state(peer_id).current_combo_step == -1: attack_runtime(peer_id).display_combo_step = 0
	return accepted

func set_combo_enabled(peer_id: int, enabled: bool) -> bool:
	if not GameMode.is_world_server() or not _endpoint.is_player_alive(peer_id): return false
	var accepted := combo_state(peer_id).set_enabled(enabled)
	if accepted and combo_state(peer_id).current_combo_step == -1: attack_runtime(peer_id).display_combo_step = 0
	return accepted

func set_combo_weapon_mode(peer_id: int, mode: StringName) -> bool:
	if not GameMode.is_world_server() or not _endpoint.is_player_alive(peer_id): return false
	var accepted := combo_state(peer_id).set_weapon_mode(mode)
	if accepted and combo_state(peer_id).current_combo_step == -1: attack_runtime(peer_id).display_combo_step = 0
	return accepted

func remember_next_facing(peer_id: int, direction: Vector2) -> void:
	if direction.length_squared() > .001:
		attack_runtime(peer_id).desired_facing = {"yaw":atan2(-direction.x,-direction.y),"time":Time.get_ticks_msec()}

func begin_attack(peer_id: int, sequence: int, now: int) -> bool:
	if not _endpoint.is_player_alive(peer_id) or sequence < 0 or sequence > 2147483647 or sequence <= attack_runtime(peer_id).sequence: return false
	if services.owner_id_for_peer(peer_id) <= 0: return false
	attack_runtime(peer_id).sequence = sequence
	var body: SpikeCharacter3D = _world.characters[peer_id]
	if body.hit_reaction.locked(now) or body.knockback_active(): return false
	if attack_runtime(peer_id).queued_sequence >= 0: return false # At most one next intent.
	var active: Dictionary = attack_runtime(peer_id).active_action
	var chained := false
	if not active.is_empty():
		var elapsed := now-int(active.started)
		var timing: Dictionary = active.timing
		if elapsed < int(timing.preinput): return false
		# Finishers start a new chain at their end; malformed native final input
		# windows (04 Direct > Limit) are never treated as an early chain link.
		var restart: bool = active.finisher or elapsed > int(timing.limit)
		if now < attack_runtime(peer_id).next_attack_ms:
			active["restart_queued"] = restart
			attack_runtime(peer_id).queued_sequence = sequence
			return true
		if restart: combo_state(peer_id).reset()
		chained = not restart
	return _start_attack(peer_id,sequence,now,chained)

func _start_attack(peer_id: int, sequence: int, now: int, chained: bool = false) -> bool:
	var attack := services.runtime_attack(services.owner_id_for_peer(peer_id))
	var ratio := services.runtime_attack_speed_ratio(services.owner_id_for_peer(peer_id))
	if attack < 0 or ratio <= 0: return false
	var resolved := combo_state(peer_id).take_step(now,chained)
	if resolved.is_empty(): return false
	var hit: BasicAttackStepDefinition = resolved.step
	if OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-legacy-melee"): hit.combat_trace = null
	var body: SpikeCharacter3D = _world.characters[peer_id]
	var facing: Dictionary = attack_runtime(peer_id).desired_facing
	if not facing.is_empty() and (now-int(facing.time) <= 500 or (not attack_runtime(peer_id).active_action.is_empty() and int(facing.time) >= int(attack_runtime(peer_id).active_action.started))): body.rotation.y = facing.yaw
	attack_runtime(peer_id).desired_facing = {}
	var timing := hit.scaled_timing(ratio)
	attack_runtime(peer_id).display_combo_step = int(resolved.step_index)+1
	var next_delay: int = timing.end if resolved.finisher else timing.direct
	attack_runtime(peer_id).next_attack_ms = now+next_delay
	attack_runtime(peer_id).movement_unlock_ms = now+int(timing.motion)
	body.start_attack_advance(body.rotation.y,hit.advance_distance,int(timing.motion)/1000.0)
	resolved.merge({"yaw":body.rotation.y,"impact":now+int(timing.impact),"started":now,"hit_set":{},
		"attack":attack,"ratio":ratio,"timing":timing,"action_id":sequence})
	_attack_order += 1
	if attack_runtime(peer_id).pending_impact.is_empty(): attack_runtime(peer_id).pending_order = _attack_order
	if attack_runtime(peer_id).active_action.is_empty(): attack_runtime(peer_id).active_order = _attack_order
	attack_runtime(peer_id).pending_impact = resolved
	attack_runtime(peer_id).active_action = resolved
	_endpoint.publish_swing(peer_id,resolved)
	return true

func advance_queue(now: int) -> void:
	for peer_id: int in ordered_peers(false):
		var active: Dictionary = attack_runtime(peer_id).active_action
		var body: SpikeCharacter3D = _world.characters.get(peer_id)
		if not _endpoint.is_player_alive(peer_id) or body == null or body.hit_reaction.locked(now) or body.knockback_active():
			cancel(peer_id)
			continue
		if now < attack_runtime(peer_id).next_attack_ms: continue
		if attack_runtime(peer_id).queued_sequence >= 0:
			var sequence: int = attack_runtime(peer_id).queued_sequence
			attack_runtime(peer_id).queued_sequence = -1
			if active.get("restart_queued",false): combo_state(peer_id).reset()
			_start_attack(peer_id,sequence,now,not active.get("restart_queued",false))
		elif now > int(active.started)+maxi(int(active.timing.motion),int(active.timing.limit)):
			combo_state(peer_id).reset()
			attack_runtime(peer_id).active_action = {}

func cancel(peer_id: int) -> void:
	var body: SpikeCharacter3D = _world.characters.get(peer_id)
	if body != null: body.cancel_attack_advance()
	if _attack_runtimes.has(peer_id): _attack_runtimes[peer_id].clear_intents()


func remove_peer(peer_id: int) -> void:
	cancel(peer_id)
	_attack_runtimes.erase(peer_id)

func combo_snapshot() -> Dictionary:
	var combos: Dictionary = {}
	for id: int in _attack_runtimes:
		if _attack_runtimes[id].display_combo_step > 0: combos[id] = _attack_runtimes[id].display_combo_step
	return combos

func movement_unlock(peer_id: int) -> int:
	return 0 if not _attack_runtimes.has(peer_id) else _attack_runtimes[peer_id].movement_unlock_ms

func request_intent(peer_id: int, sequence: int, now: int) -> int:
	if sequence < 0 or sequence > 2147483647 or sequence <= attack_runtime(peer_id).sequence: return 0
	if not begin_attack(peer_id,sequence,now) and _endpoint.is_player_alive(peer_id) and attack_runtime(peer_id).queued_sequence < 0:
		var body: SpikeCharacter3D = _world.characters[peer_id]
		var retry_at: int = maxi(attack_runtime(peer_id).next_attack_ms,body.hit_reaction.get_up_until_ms)
		var active: Dictionary = attack_runtime(peer_id).active_action
		if not active.is_empty() and now < int(active.started)+int(active.timing.preinput): retry_at = int(active.started)+int(active.timing.preinput)
		return maxi(100,retry_at-now+10)
	return 0

func resolve_swing(peer_id: int, swing: Dictionary, now: int) -> Array[int]:
	var hit_ids: Array[int] = []
	if not _endpoint.is_player_alive(peer_id) or _world.characters[peer_id].hit_reaction.locked(now): return hit_ids
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
		if dog == null or hit_set.has(dog.mob_id) or dog.ai_state in [MobState.Value.DEAD, MobState.Value.RETURN, MobState.Value.DISABLED]: continue
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
		_endpoint.apply_mob_hit(dog,peer_id,result,horizontal if horizontal.length_squared() > 0.001 else forward,now)
		var event := result.presentation()
		event["id"] = dog.mob_instance_id
		event["target_kind"] = "mob"
		event["target_id"] = dog.mob_instance_id
		results.append(event)
	_endpoint.publish_hits(peer_id,results,swing)
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


func process_impacts(now: int) -> void:
	for peer_id: int in ordered_peers(true):
		var runtime := attack_runtime(peer_id)
		if now >= int(runtime.pending_impact.impact):
			var swing: Dictionary = runtime.pending_impact
			runtime.pending_impact = {}
			resolve_swing(peer_id,swing,now)
