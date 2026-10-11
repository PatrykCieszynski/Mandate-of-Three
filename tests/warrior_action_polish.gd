extends "res://tests/pve_network.gd"
## Opt-in action contracts, real physics/transport, no animation timing in smoke.
@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, _uid: String) -> void:
	if command != "DONE": return
	var body: SpikeCharacter3D = world.characters[world.local_peer]
	var visible_yaw := body.rotation.y+body.player_presentation.rotation.y
	body.accept_swing_facing(PI/2)
	body.play_swing(BasicAttackCombos.BASE.steps[0].animation_key,1000)
	check(is_equal_approx(body.rotation.y,PI/2),"accepted gameplay yaw is immediate")
	check(is_equal_approx(wrapf(body.rotation.y+body.player_presentation.rotation.y-visible_yaw,-PI,PI),0),"presentation preserves old visible yaw at transition")
	await get_tree().create_timer(.12).timeout
	check(is_zero_approx(body.player_presentation.rotation.y) and is_equal_approx(body.rotation.y,PI/2),"visual blend reaches authoritative yaw without rotating gameplay")
	if failed: return
	print("ACTION_CLIENT_OK ",client_number)
	finished.rpc_id(1)
	await get_tree().create_timer(.5).timeout
	peer.close()
	get_tree().quit()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	var combat := world.combat_endpoint
	world.set_physics_process(false)
	combat.set_physics_process(false)
	for dog: SpikeWildDog3D in combat.dogs.values(): dog.ai_enabled = false
	var hero: int = world.characters.keys()[0]
	var body: SpikeCharacter3D = world.characters[hero]
	var stats: Dictionary = server.runtime_equipment[server.connected_players[hero].player_id].stats
	stats.attack_speed = 100.0
	body.position = Vector3(0,0,5)
	body.rotation.y = 0
	var target: SpikeWildDog3D = combat.dogs[1]
	target.position = Vector3(0,0,3.6)
	await get_tree().physics_frame
	var now := Time.get_ticks_msec()
	check(combat.begin_attack(hero,100,now),"accept hitch fixture")
	var swing: Dictionary = combat._active_attacks[hero]
	check(combat.resolve_swing(hero,swing,now+200).is_empty(),"scheduled hit cannot resolve early")
	var before := target.hp
	check(combat.resolve_swing(hero,swing,now+400).has(target.mob_id),"late tick resolves scheduled impact beyond active-window end")
	check(target.hp < before and combat.resolve_swing(hero,swing,now+500).is_empty(),"late hit applies exactly once")
	check(not combat.can_move(hero,now+int(swing.timing.direct)),"link does not unlock WASD")
	check(combat.can_move(hero,now+int(swing.timing.motion)),"motion end unlocks WASD")
	check(combat.begin_attack(hero,101,now+int(swing.timing.preinput)),"next intent queues")
	combat.remember_next_facing(hero,Vector2.RIGHT)
	combat._advance_attack_queue(now+int(swing.timing.direct))
	var next: Dictionary = combat._active_attacks[hero]
	check(next.step_index == 1 and is_equal_approx(next.yaw,-PI/2) and is_zero_approx(swing.yaw),"link starts new action with its own frozen yaw")
	check(is_equal_approx(body._advance_yaw,next.yaw) and not combat.can_move(hero,now+int(swing.timing.direct)),"successor owns advance and movement lock")
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2,2,.2)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(10,1,8.7)
	world.add_child(wall)
	await get_tree().physics_frame
	var distances: Array[float] = []
	var ticks: Array[int] = []
	var seq := 200
	for speed: float in [100.0,122.0,150.0]:
		combat._clear_attack_intents(hero)
		combat.combo_state(hero).reset()
		combat._next_attack_ms.erase(hero)
		stats.attack_speed = speed
		body.position = Vector3(12,0,10)
		body.velocity = Vector3.ZERO
		body.rotation.y = 0
		var start := body.position
		var started := Time.get_ticks_msec()
		check(combat.begin_attack(hero,seq,started),"accept advance at each speed")
		seq += 1
		var frame := 0
		var advance_ticks := 0
		var motion_ms: int = combat._active_attacks[hero].timing.motion
		while frame*1000.0/60 < motion_ms:
			await get_tree().physics_frame
			var direction := Vector2.RIGHT if combat.can_move(hero,started+int(frame*1000.0/60)) else Vector2.ZERO
			body.simulate(1.0/60,direction)
			frame += 1
			if advance_ticks == 0 and body._advance_elapsed >= body._advance_duration: advance_ticks = frame
		check(absf(body.position.x-start.x)<.01,"input cannot walk during motion")
		distances.append(start.z-body.position.z)
		ticks.append(advance_ticks)
		# Advance is finished at link; action movement lock still covers the tail.
		check(not combat.can_move(hero,started+int(combat._active_attacks[hero].timing.direct)),"single attack tail remains locked")
	check(absf(distances[0]-distances[1])<.02 and absf(distances[0]-distances[2])<.02 and absf(distances[0]-BasicAttackCombos.BASE.steps[0].advance_distance)<.03,"speed preserves authored advance distance")
	check(ticks[0]>ticks[1] and ticks[1]>ticks[2],"higher speed shortens advance duration")
	print("ACTION_ADVANCE distances=",distances," ticks=",ticks)
	combat._clear_attack_intents(hero)
	combat.combo_state(hero).reset()
	combat._next_attack_ms.erase(hero)
	stats.attack_speed = 100.0
	body.position = Vector3(10,0,10)
	body.velocity = Vector3.ZERO
	body.rotation.y = 0
	check(combat.begin_attack(hero,seq,Time.get_ticks_msec()),"accept wall advance")
	while body._advance_elapsed < body._advance_duration:
		await get_tree().physics_frame
		body.simulate(1.0/60,Vector2.ZERO)
	check(body.position.z > 9.1 and body.position.z < 9.8,"advance hits scenery without passing through it: pos=%s wall=%s mask=%d" % [body.global_position,wall.global_position,body.collision_mask])
	var rig := MandateCamera3D.new()
	add_child(rig)
	var yaw := rig.desired_yaw
	var pitch := rig.desired_pitch
	for id: int in 20: rig.confirm_finisher({"action_id":1,"finisher":true,"damage":5,"target_id":id},true)
	check(rig.finisher_impulses == 1,"multi-target finisher shakes once per action")
	check(not rig.confirm_finisher({"action_id":2,"finisher":true,"damage":0},true) and not rig.confirm_finisher({"action_id":3,"finisher":true,"damage":5},false),"miss and remote finisher do not shake")
	rig._tick_impulse(.12)
	check(rig.camera.h_offset == 0 and rig.camera.v_offset == 0 and rig.desired_yaw == yaw and rig.desired_pitch == pitch,"shake decays without persistent orbit change")
	rig.free()
	var trail := SwordTrail3D.new()
	add_child(trail)
	var mesh := trail.mesh
	for i: int in 10:
		trail.sample(.01,Vector3(i*.1,0,0),Vector3(i*.1,1,0),true)
		check(trail.mesh == mesh,"trail reuses one mesh resource")
	trail.clear()
	check(trail.mesh == mesh and trail.points.is_empty(),"clear retains reusable resource")
	trail.free()
	if failed: return
	print("ACTION_SERVER_OK hitch, locks, forward advance/collision, frozen yaw, shake and resource reuse")
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	peer.close()
	db.close_db()
	get_tree().quit()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 30: check(false,"action test timeout")
	if GameMode.is_world_server() or world == null or world.combat_endpoint.state.is_empty(): return
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer] = true
		register_ready.rpc_id(1)
