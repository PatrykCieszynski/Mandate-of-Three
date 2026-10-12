extends "res://tests/pve_network.gd"
## Production World damage path, two clients and dense single-hit/dedupe contract.
@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, _uid: String) -> void:
	phase_name = command
	if command == "DONE":
		for id: int in range(1001,1101): check(world.mob_system.mobs.has(id) and world.mob_system.mobs[id].hp == 110,"authoritative dense damage replicated once")
		print("TRACE_CLIENT_OK ",client_number)
		finished.rpc_id(1)
		await get_tree().create_timer(.5).timeout
		peer.close()
		get_tree().quit()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	check(world.find_children("*","AnimationPlayer",true,false).is_empty() and world.find_children("*","Skeleton3D",true,false).is_empty(),"World trace path has no animation or skeleton runtime")
	var combat := world.combat_endpoint
	for dog: SpikeMob3D in world.mob_system.mobs.values(): dog.ai_enabled = false
	var hero: int = world.characters.keys()[0]
	world.characters[hero].position = Vector3(0,0,5)
	world.characters[hero].rotation.y = 0
	for id: int in range(1001,1101):
		var dog := SpikeMob3D.new()
		dog.setup_mob(id,Vector3((id%10-5)*.04,0,3.6))
		dog.ai_enabled = false
		world.add_child(dog)
		world.mob_system.mobs[id] = dog
		if id == 1001: dog.add_child(dog.get_child(0).duplicate())
	await get_tree().physics_frame
	# Baked production geometry is actually used, not the synthetic test trace.
	for count: int in [50,100]:
		for id: int in range(1001,1101):
			world.mob_system.mobs[id].hp = 120
			world.mob_system.mobs[id].position.z = 3.6 if id < 1001+count else -10
		await get_tree().physics_frame
		var step := BasicAttackCombos.BASE.steps[0].duplicate() as BasicAttackStepDefinition
		var now := Time.get_ticks_msec()
		var swing := {"step":step,"yaw":0.0,"started":now-step.impact_ms,"impact":now,"attack":10,"hit_set":{}}
		var started := Time.get_ticks_usec()
		var hits := combat.attacks.resolve_swing(hero,swing,now)
		var dense := 0
		for id: int in hits: if id >= 1001: dense += 1
		check(dense == count,"baked trace reaches all %d candidates" % count)
		check(combat.attacks.resolve_swing(hero,swing,now).is_empty(),"same swing cannot apply damage twice")
		for id: int in range(1001,1001+count): check(world.mob_system.mobs[id].hp == 110,"one damage per target despite several samples/shapes")
		print("TRACE_DENSE count=",count," hits=",dense," usec=",Time.get_ticks_usec()-started)
	# Low defenders beneath an unmodified high production swing (02). The literal
	# broadphase cannot reach their capsule tops; forgiveness must include them.
	var high_step := BasicAttackCombos.BASE.steps[1].duplicate() as BasicAttackStepDefinition
	for id: int in range(1001,1101):
		world.mob_system.mobs[id].hp = 120
		world.mob_system.mobs[id].position = Vector3((id%10-5)*.04,-.5,3.6 if id < 1051 else -10)
	await get_tree().physics_frame
	var high_now := Time.get_ticks_msec()
	var high_swing := {"step":high_step,"yaw":0.0,"started":high_now-high_step.impact_ms,"impact":high_now,"attack":10,"hit_set":{}}
	var low_hits := combat.attacks.resolve_swing(hero,high_swing,high_now)
	var low_count := 0
	for id: int in low_hits: if id >= 1001: low_count += 1
	check(low_count == 50,"high baked swing reaches 50 low defenders")
	check(combat.attacks.resolve_swing(hero,high_swing,high_now).is_empty(),"low target swing cannot repeat damage")
	for id: int in range(1001,1101):
		check(world.mob_system.mobs[id].hp == (110 if id < 1051 else 120),"low target damage is unique and horizontal range is preserved")
		world.mob_system.mobs[id].position = Vector3((id%10-5)*.04,0,3.6)
	await get_tree().physics_frame
	print("TRACE_LOW_DENSE count=50 hits=",low_count)
	# Active-window guard and no-trace fallback use the same production endpoint.
	var step := BasicAttackCombos.BASE.steps[0].duplicate() as BasicAttackStepDefinition
	var now := Time.get_ticks_msec()
	for scheduled_ms: int in [step.hit_start_ms-1,step.hit_end_ms+1]:
		var invalid := step.duplicate() as BasicAttackStepDefinition
		invalid.impact_ms = scheduled_ms
		check(combat.attacks.resolve_swing(hero,{"step":invalid,"yaw":0.0,"impact":now,"attack":10},now).is_empty(),"no hit with a scheduled impact outside canonical active window")
	step.combat_trace = null
	var legacy_hits := combat.attacks.resolve_swing(hero,{"step":step,"yaw":0.0,"impact":now,"attack":1},now)
	check(legacy_hits.size() >= 100,"legacy fallback remains functional without the old 64 limit")
	# Restore expected final state for observers after the explicit fallback probe.
	for id: int in range(1001,1101): world.mob_system.mobs[id].hp = 110
	combat._send_snapshot()
	await get_tree().create_timer(.3).timeout
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	print("TRACE_SERVER_OK baked geometry, one-hit damage, active window, dense pulls and fallback")
	peer.close()
	db.close_db()
	get_tree().quit()
