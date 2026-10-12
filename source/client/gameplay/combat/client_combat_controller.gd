class_name ClientCombatController
extends RefCounted
## Target/input and basic-attack presentation only. Loot/XP/HUD stay at the facade.
var selected_target: Dictionary = {}
var autoattack: bool = false
var _client_sequence: int = 0
var _client_request_at: int = -1
var _client_intent_sent: bool = false
var _client_was_active: bool = false
var _feedback: CombatFeedback3D
var _trace_debug: Dictionary[int, CombatTraceDebug3D] = {}
var trace_debug_enabled: bool = false
var _world: GameWorld3D
var _endpoint: Node

func setup(world: GameWorld3D, endpoint: Node) -> void:
	_world = world
	_endpoint = endpoint
	trace_debug_enabled = OS.has_feature("editor") and (OS.get_cmdline_user_args().has("--combat-trace-debug") or (DisplayServer.get_name() != "headless" and FileAccess.file_exists("res://.godot/runtime/trace-debug.enabled")))


func receive_attack_wait(delay_ms: int) -> void:
	if not GameMode.is_client(): return
	_client_intent_sent = false
	_client_request_at = Time.get_ticks_msec()+delay_ms


func receive_swing(peer_id: int, animation_key: StringName, step_index: int, motion_ms: int, finisher: bool, ratio: float = 1.0, action_id: int = 0, yaw: float = 0.0, preinput_ms: int = 0) -> void:
	if not GameMode.is_client(): return
	var body: PlayerActor3D = _world.characters.get(peer_id)
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
			for dog: MobActor3D in _world.mob_system.mobs.values():
				targets.append({"id":dog.mob_id,"position":overlay.to_local(dog.global_position),"radius":dog.combat_radius(),"height":dog.combat_height(),"bottom_offset":dog.combat_bottom_offset()})
			overlay.configure(step,targets,OS.get_cmdline_user_args().has("--dev-legacy-melee"))
			_trace_debug[peer_id] = overlay
	_endpoint.publish_swing_presentation(peer_id,animation_key,step_index)


func receive_hits(peer_id: int, results: Array[Dictionary], action_id: int = 0, step_index: int = 0, finisher: bool = false) -> void:
	if not GameMode.is_client(): return
	if _trace_debug.has(peer_id): _trace_debug[peer_id].mark_hits(results)
	if _feedback == null:
		_feedback = CombatFeedback3D.new()
		_world.add_child(_feedback)
	for result: Dictionary in results:
		var target: Node3D = _world.mob_system.mobs.get(int(result.id))
		if int(result.id) == -1 and _world.metin_encounter != null:
			if str(result.get("target_id","")) == _world.metin_encounter.runtime.stone_instance_id: target = _world.metin_encounter.stone
		var event := result.duplicate()
		event.merge({"attacker":peer_id,"action_id":action_id,"step_index":step_index,"finisher":finisher})
		if target != null and _feedback.confirm(event,target,peer_id == _world.local_peer):
			_endpoint.publish_confirmed_hit(event)
			if _world.camera_controller != null: _world.camera_controller.confirm_finisher(event,peer_id == _world.local_peer)
		var body: MobActor3D = _world.mob_system.mobs.get(int(result.id))
		if body != null: present_reaction(body,result)
	if peer_id == _world.local_peer:
		_endpoint.set_notice("Trafiono: %d" % results.size())
		_endpoint.refresh_hud()


func receive_hurt(peer_id: int, result: Dictionary) -> void:
	if not GameMode.is_client(): return
	var body: PlayerActor3D = _world.characters.get(peer_id)
	if body != null: present_reaction(body,result)
	if peer_id == _world.local_peer and (int(result.reaction) == HitReaction.Type.KNOCKDOWN or (body != null and not body.alive)):
		_client_intent_sent = false
		_client_request_at = Time.get_ticks_msec()+int((float(result.duration)+float(result.get_up_duration))*1000)+100


func present_reaction(body: Actor3D, result: Dictionary) -> void:
	match int(result.reaction):
		HitReaction.Type.FLINCH, HitReaction.Type.KNOCKBACK: body.play_hit()
		HitReaction.Type.KNOCKDOWN:
			body.present_hit_lock(int(float(result.duration)*1000),int(float(result.get_up_duration)*1000))


func resolve_target(target: Dictionary) -> Node3D:
	if target.is_empty(): return null
	match target.get("kind"):
		&"mob":
			var dog: MobActor3D = _world.mob_system.mobs.get(int(target.get("id",0)))
			if not is_instance_valid(dog) or dog.is_queued_for_deletion() or dog.hp <= 0 or dog.ai_state in [MobState.Value.DEAD,MobState.Value.DISABLED]: return null
			return dog
		&"metin":
			var encounter: MetinEncounter = _world.metin_encounter
			if not is_instance_valid(encounter) or not encounter.active() or encounter.runtime.hp <= 0 or encounter.runtime.stone_instance_id != str(target.get("id","")): return null
			return encounter.stone if is_instance_valid(encounter.stone) and not encounter.stone.is_queued_for_deletion() else null
	return null


func clear_invalid_target() -> void:
	if resolve_target(selected_target) == null and (not selected_target.is_empty() or autoattack):
		select_target({})


func select_target(target: Dictionary) -> void:
	if not target.is_empty(): _world.cancel_npc_approach()
	selected_target = target.duplicate()
	if resolve_target(selected_target) == null: selected_target = {}
	for dog: MobActor3D in _world.mob_system.mobs.values():
		if is_instance_valid(dog) and not dog.is_queued_for_deletion():
			dog.mark_selected(selected_target.get("kind") == &"mob" and dog.mob_id == int(selected_target.get("id",0)))
	if selected_target.is_empty(): autoattack = false
	_endpoint.refresh_hud()


func handle_input(event: InputEvent) -> void:
	if not GameMode.is_client() or not _world.input_enabled or ClientState.menu_open: return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var camera: Camera3D = _world.gameplay_camera()
		var origin: Vector3 = camera.project_ray_origin(event.position)
		var ray := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(event.position) * 100, 4)
		var hit: Dictionary = _world.get_world_3d().direct_space_state.intersect_ray(ray)
		var dog: MobActor3D = hit.get("collider") as MobActor3D
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
			_endpoint.set_notice("Combat trace debug: " + ("ON" if trace_debug_enabled else "OFF"))
			_endpoint.refresh_hud()
			_world.get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_C:
			_endpoint.request_combo_toggle.rpc_id(1)
			_world.get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_F:
			clear_invalid_target()
			autoattack = not autoattack and not selected_target.is_empty()
			_endpoint.refresh_hud()
			_world.get_viewport().set_input_as_handled()

func assist_direction(manual: Vector2) -> Vector2:
	clear_invalid_target()
	if manual.length_squared() > 0.001:
		autoattack = false
		return manual
	if not autoattack or not _world.characters.has(_world.local_peer): return manual
	var actor: Node3D = resolve_target(selected_target)
	if actor == null:
		autoattack = false
		return Vector2.ZERO
	var body: PlayerActor3D = _world.characters[_world.local_peer]
	var offset: Vector3 = actor.position - body.position
	var direction := Vector2(offset.x, offset.z).normalized()
	if Vector2(offset.x, offset.z).length() > 1.7: return direction
	var forward := Vector2(-sin(body.rotation.y), -cos(body.rotation.y))
	return direction * 0.05 if forward.dot(direction) < 0.98 else Vector2.ZERO


func process(delta: float) -> void:
	if not GameMode.is_client(): return
	clear_invalid_target()
	if not _world.input_enabled or ClientState.menu_open or not DisplayServer.window_is_focused(): return
	var active: bool = Input.is_physical_key_pressed(KEY_SPACE)
	if autoattack and _world.characters.has(_world.local_peer):
		var actor: Node3D = resolve_target(selected_target)
		active = actor != null and _world.characters[_world.local_peer].position.distance_to(actor.position) <= BasicAttackService.ATTACK_REACH
	active = active and _world.characters.has(_world.local_peer) and _world.characters[_world.local_peer].alive
	if active and not _client_was_active and _client_request_at < 0: _client_intent_sent = false
	if active and not _client_intent_sent and Time.get_ticks_msec() >= _client_request_at:
		_client_intent_sent = true
		_client_request_at = -1
		_client_sequence += 1
		_endpoint.request_attack.rpc_id(1,_client_sequence)
	if not active:
		_client_intent_sent = false
	_client_was_active = active


func remove_peer(peer_id: int) -> void:
	if _trace_debug.has(peer_id):
		_trace_debug[peer_id].queue_free()
		_trace_debug.erase(peer_id)

func snapshot_changed(snapshot: Dictionary) -> void:
	for id: int in _trace_debug.keys():
		if not snapshot.health.has(id): remove_peer(id)
	clear_invalid_target()
	if int(snapshot.health.get(_world.local_peer,0)) <= 0: autoattack = false

func dispose() -> void:
	for overlay: CombatTraceDebug3D in _trace_debug.values():
		if is_instance_valid(overlay): overlay.queue_free()
	_trace_debug.clear()
	if is_instance_valid(_feedback): _feedback.queue_free()
	_feedback = null
	selected_target = {}
	autoattack = false
