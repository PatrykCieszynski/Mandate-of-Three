extends "res://tests/pve_network.gd"
## Production combat RPC and client reconciliation; only observer/mob placement
## is controlled. Reuses existing two-client/SQLite lifecycle, not a load test.
var expected: Dictionary = {}
var observation: int = 0
var observed_instances: Dictionary[int, int] = {}

@rpc("authority", "call_remote", "reliable", 0)
func observe(request: Dictionary) -> void:
	expected = request

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
