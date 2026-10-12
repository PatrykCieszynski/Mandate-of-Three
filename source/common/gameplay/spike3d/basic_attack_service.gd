class_name BasicAttackService
extends RefCounted
## Existing basic attack orchestration; resolvers and actor policy stay separate.
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
