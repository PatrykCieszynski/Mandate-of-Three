extends "res://tests/pve_network.gd"
## Optional two-client production RPC check. Reuses the isolated map/session fixture.
var listening: bool = false

@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "DONE":
		check(not world.npc_endpoint.state.active, "Context closed on both clients")
		if not failed:
			print("NPC_CLIENT_OK: ", client_number, " interaction/service/close/private state")
			finished.rpc_id(1)
			await get_tree().create_timer(0.3).timeout
			world.process_mode = Node.PROCESS_MODE_DISABLED
			peer.close()
			get_tree().quit()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	for dog: SpikeWildDog3D in world.combat_endpoint.dogs.values(): dog.ai_enabled = false
	var hero: int = world.characters.keys()[0]
	var other: int = world.characters.keys()[1]
	var npc: NeutralNpc3D = world.npc_endpoint.actors["spike-blacksmith-01"]
	drop_uid = npc.instance_id
	world.characters[hero].position = npc.position + Vector3(0,0,2)
	world.characters[other].position = Vector3(12,0,12)
	set_phase("INTERACT", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].active and replies[hero].npc == npc.instance_id, "RPC establishes context and private snapshot")
	check(not world.npc_endpoint.contexts.has(other), "Other client never gains interaction rights")
	set_phase("SELECT", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].selected == "weapon_shop", "RPC selects authoritative service")
	var authorized: Dictionary = world.npc_endpoint.resolve_npc_service(hero, npc.instance_id, &"weapon_shop", NpcServiceDefinition.Kind.SHOP)
	check(authorized.ok and authorized.content_ref == &"blacksmith_weapon_shop", "Shop domain receives configured content reference")
	set_phase("CLOSE", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and not replies[hero].active and not world.npc_endpoint.contexts.has(hero), "Explicit close clears server and client context")
	await get_tree().create_timer(0.15).timeout
	set_phase("INTERACT", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok, "Interaction can reopen")
	world.characters[hero].position = Vector3(12,0,12)
	set_phase("STALE", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and replies[hero].error in ["out_of_range", "no_interaction"] and not replies[hero].active, "Moved player cannot use stale service context")
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	if not failed:
		print("NPC_SERVER_OK: production RPC, private snapshots, service content, close and stale range")
		world.process_mode = Node.PROCESS_MODE_DISABLED
		peer.close()
		db.close_db()
		get_tree().quit()

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 25:
		check(false, "NPC network timeout: " + phase_name)
		return
	if GameMode.is_world_server() or world == null or world.combat_endpoint.state.is_empty(): return
	if not listening:
		listening = true
		world.npc_endpoint.operation_finished.connect(func(_id: String, result: Dictionary) -> void:
			var snapshot: Dictionary = world.npc_endpoint.state
			var reply: Dictionary = result.duplicate(true)
			reply.merge({"active":snapshot.active, "npc":snapshot.get("npcInstanceId", ""), "selected":snapshot.get("selectedServiceId", "")})
			report.rpc_id(1, reply))
		register_ready.rpc_id(1)
	if phase_name == "WAIT" or phase_name == "DONE" or attempted: return
	attempted = true
	match phase_name:
		"INTERACT": world.npc_endpoint.request_interaction.rpc_id(1, "interact", drop_uid, "", "network-interact")
		"SELECT", "STALE": world.npc_endpoint.request_interaction.rpc_id(1, "select", drop_uid, "weapon_shop", "network-select")
		"CLOSE": world.npc_endpoint.request_interaction.rpc_id(1, "close", "", "", "network-close")
