extends "res://tests/pve_network.gd"
## Production combat RPC and client reconciliation; only observer/mob placement
## is controlled. Reuses existing two-client/SQLite lifecycle, not a load test.
var expected: Dictionary = {}
var observation: int = 0
var motion_observation: Dictionary = {}
var observed_instances: Dictionary[int, int] = {}

@rpc("authority", "call_remote", "reliable", 0)
func observe(request: Dictionary) -> void:
	expected = request

@rpc("authority", "call_remote", "reliable", 0)
func begin_motion(tag: int) -> void:
	var mob: MobActor3D = world.mob_system.mobs[1]
	motion_observation = {"position": mob.position.x, "target": mob.target_position.x,
		"hp": mob.hp, "motion": 0, "hp_only": 0, "actor": mob.get_instance_id()}
	report.rpc_id(1, {"ok": true, "tag": tag})

@rpc("authority", "call_remote", "reliable", 0)
func end_motion(tag: int, interval_ms: int) -> void:
	check(int(motion_observation.motion) >= 2, "sustained movement reaches the client")
	check(int(motion_observation.hp_only) >= 2, "HP changes arrive between movement updates")
	print("AOI_MOTION_OK interval_ms=", interval_ms, " motion=", motion_observation.motion,
		" hp_without_motion=", motion_observation.hp_only, " no target/render rewind")
	motion_observation = {}
	report.rpc_id(1, {"ok": true, "tag": tag})

func sample_motion() -> void:
	if motion_observation.is_empty(): return
	var mob: MobActor3D = world.mob_system.mobs[1]
	check(mob.get_instance_id() == int(motion_observation.actor), "moving actor is retained")
	check(mob.position.x + 0.0001 >= float(motion_observation.position), "rendered motion never rewinds on HP update")
	check(mob.target_position.x + 0.0001 >= float(motion_observation.target), "network target never rewinds on HP update")
	if mob.target_position.x > float(motion_observation.target):
		motion_observation.motion += 1
	elif mob.hp != int(motion_observation.hp):
		motion_observation.hp_only += 1
	motion_observation.position = mob.position.x
	motion_observation.target = mob.target_position.x
	motion_observation.hp = mob.hp

func moving_hp_updates(peers: Array, interval_ms: int) -> void:
	world.combat_endpoint._mob_replication.position_interval_ms = interval_ms
	observation += 1
	for id: int in peers: begin_motion.rpc_id(id, observation)
	await wait_until(func() -> bool:
		return peers.all(func(id: int) -> bool: return replies.get(id, {}).get("tag", -1) == observation))
	var mob: MobActor3D = world.mob_system.mobs[1]
	var changed_after_motion: int = -1
	var until: int = Time.get_ticks_msec() + 2200
	while Time.get_ticks_msec() < until and not failed:
		await get_tree().physics_frame
		mob.position.x += 2.0 * get_physics_process_delta_time()
		var baseline: Dictionary = world.combat_endpoint._mob_replication._peers[peers[0]]
		var motion_at: int = baseline.motion_at[1]
		var age: int = Time.get_ticks_msec() - motion_at
		# Force one real combat RPC between scheduled transforms. Production
		# periodic publication remains enabled; only fixture HP/motion is driven.
		if motion_at != changed_after_motion and age >= 30 and age < interval_ms:
			changed_after_motion = motion_at
			mob.hp -= 1
			world.combat_endpoint._send_snapshot()
	for id: int in peers: await view(id, [1], mob.hp)
	observation += 1
	for id: int in peers: end_motion.rpc_id(id, observation, interval_ms)
	await wait_until(func() -> bool:
		return peers.all(func(id: int) -> bool: return replies.get(id, {}).get("tag", -1) == observation))

@rpc("authority", "call_remote", "reliable", 0)
func complete_aoi() -> void:
	print("AOI_CLIENT_OK visibility, sparse retention, death/removal and re-entry")
	finished.rpc_id(1)
	await get_tree().create_timer(0.3).timeout
	peer.close()
	get_tree().quit()

func view(peer_id: int, ids: Array, hp: int = -1) -> void:
	observation += 1
	var tag := observation
	observe.rpc_id(peer_id, {"tag": tag, "ids": ids, "hp": hp})
	await wait_until(func() -> bool: return replies.get(peer_id, {}).get("tag", -1) == tag)
	check(replies[peer_id].ok, "client retains existing actor identity on sparse updates")

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	var peers: Array = world.characters.keys()
	var limits := world.services.startup_limits()
	var spacing: float = limits.value("mob_aoi_exit_radius") * 3.0
	var boundary: float = (limits.value("mob_aoi_enter_radius") + limits.value("mob_aoi_exit_radius")) / 2.0
	for id: int in world.mob_system.mobs:
		var mob: MobActor3D = world.mob_system.mobs[id]
		mob.ai_enabled = false
		mob.position = Vector3((id - 1) * spacing, 0, 0)
	world.characters[peers[0]].position = Vector3.ZERO
	world.characters[peers[1]].position = Vector3(spacing, 0, 0)
	await view(peers[0], [1])
	await view(peers[1], [2])
	# No mob movement; multiple sparse frames must retain actors and state.
	await get_tree().create_timer(0.4).timeout
	await view(peers[0], [1])
	world.characters[peers[1]].position = Vector3.ZERO
	await view(peers[1], [1])
	for interval_ms: int in [100, 150, 200]:
		await moving_hp_updates(peers, interval_ms)
	world.combat_endpoint._mob_replication.position_interval_ms = limits.value("mob_position_interval_ms")
	world.mob_system.mobs[1].position = Vector3.ZERO
	world.characters[peers[1]].position = Vector3(spacing, 0, 0)
	await view(peers[1], [2])
	world.characters[peers[0]].position = Vector3(boundary, 0, 0)
	world.characters[peers[1]].position = Vector3(boundary, 0, 0)
	await view(peers[0], [1])
	await view(peers[1], [])
	world.characters[peers[0]].position = Vector3(limits.value("mob_aoi_exit_radius") + 1, 0, 0)
	await view(peers[0], [])
	world.characters[peers[0]].position = Vector3.ZERO
	await view(peers[0], [1])
	world.mob_system.mobs[1].hp = 0
	world.mob_system.die(world.mob_system.mobs[1], Time.get_ticks_msec())
	await view(peers[0], [1], 0)
	world.mob_system.remove_mob(1)
	await view(peers[0], [])
	for id: int in world.characters: complete_aoi.rpc_id(id)
	await wait_until(func() -> bool: return done_peers.size() == 2)
	print("AOI_SERVER_OK two observer sets and authoritative lifecycle")
	db.close_db()
	get_tree().quit()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 25:
		check(false, "AOI timeout tag=" + str(observation) + " ready=" + str(ready_peers.keys()) + " expected=" + str(expected))
		return
	if GameMode.is_world_server() or world == null or world.combat_endpoint.state.is_empty(): return
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer] = true
		register_ready.rpc_id(1)
	sample_motion()
	if expected.is_empty(): return
	var actual: Array = world.mob_system.mobs.keys()
	var wanted: Array = expected.ids.duplicate()
	actual.sort()
	wanted.sort()
	if actual != wanted: return
	if int(expected.hp) >= 0 and world.mob_system.mobs[1].hp != int(expected.hp): return
	var stable := true
	for id: int in observed_instances.keys():
		if not actual.has(id): observed_instances.erase(id)
	for id: int in actual:
		var instance: int = world.mob_system.mobs[id].get_instance_id()
		if observed_instances.has(id) and observed_instances[id] != instance: stable = false
		observed_instances[id] = instance
	report.rpc_id(1, {"ok": stable, "tag": expected.tag})
	expected = {}
