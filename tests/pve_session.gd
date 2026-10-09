extends "res://tests/items_session.gd"
## One real gateway/master/world login, combat, pickup and relog. This creates a
## local guest character; run against an otherwise quiet normal Spike instance.
var movement_sequence: int = 0

func face_or_approach(point: Vector3, stop_distance: float = 1.7) -> void:
	var body: SpikeCharacter3D = world.characters[world.local_peer]
	var offset: Vector3 = point - body.target_position
	var direction := Vector2(offset.x, offset.z).normalized()
	if Vector2(offset.x, offset.z).length() <= stop_distance: direction *= 0.05
	movement_sequence += 1
	world.submit_input.rpc_id(1, movement_sequence, direction)
	await get_tree().create_timer(0.1).timeout
	movement_sequence += 1
	world.submit_input.rpc_id(1, movement_sequence, Vector2.ZERO)

func capture(file_name: String) -> void:
	if not CmdlineUtils.get_parsed_args().has("preview"): return
	await RenderingServer.frame_post_draw
	var screenshot: Image = get_viewport().get_texture().get_image()
	if screenshot.save_png("res://.godot/verification/" + file_name) != OK:
		fail("preview save")
	else:
		print("PVE_PREVIEW_OK: ", file_name)

func run() -> void:
	var session: Dictionary = await api(GatewayAPI.guest(), {})
	if session.is_empty(): return
	var worlds: Dictionary = session.get("w", {})
	if worlds.is_empty():
		fail("no world")
		return
	var world_id: int = int(worlds.keys()[0])
	var identity: Dictionary = {"w-id": world_id, "a-id": session.id, "a-u": session.name, "t-id": session.session_id}
	await api(GatewayAPI.world_characters(), identity)
	identity["data"] = {"name": "Pve%s" % str(Time.get_ticks_usec()).right(6), "skin": 1}
	var handoff: Dictionary = await api(GatewayAPI.world_create_char(), identity)
	if handoff.is_empty(): return
	Client.connect_to_server(handoff.address, handoff.port, handoff["auth-token"])
	await wait_inventory()
	var strong: Dictionary = world.inventory_endpoint.state.items[1]
	await action("equip", strong)
	var combat: SpikeCombat3D = world.combat_endpoint
	var attack_sequence: int = 0
	while combat.state.is_empty() or combat.state.drops.is_empty() or (CmdlineUtils.get_parsed_args().has("xp-levelup") and int(combat.state.progression.level) < 2):
		var nearest: float = INF
		var point: Vector3 = Vector3.ZERO
		for dog: SpikeWildDog3D in combat.dogs.values():
			if dog.ai_state in ["DEAD", "DISABLED"]: continue
			var distance: float = world.characters[world.local_peer].target_position.distance_to(dog.target_position)
			if distance < nearest:
				nearest = distance
				point = dog.target_position
		if is_finite(nearest): await face_or_approach(point)
		attack_sequence += 1
		combat.request_attack.rpc_id(1, attack_sequence)
		if attack_sequence == 3:
			await get_tree().create_timer(0.1).timeout
			await capture("pve-combat-preview.png")
			await get_tree().create_timer(0.55).timeout
		else:
			await get_tree().create_timer(0.65).timeout
	if combat.state.drops.is_empty():
		fail("mob death with ground item")
		return
	if world.inventory_endpoint.state.items.size() != 2:
		fail("item granted before pickup")
		return
	await capture("pve-loot-preview.png")
	var uid: String = ""
	var nearest: float = INF
	for candidate: String in combat.state.drops:
		var distance: float = world.characters[world.local_peer].target_position.distance_to(combat.state.drops[candidate].position)
		if distance < nearest:
			nearest = distance
			uid = candidate
	while world.characters[world.local_peer].target_position.distance_to(combat.state.drops[uid].position) > 2.2:
		await face_or_approach(combat.state.drops[uid].position, 2.2)
	combat.request_pickup.rpc_id(1, uid)
	while world.inventory_endpoint.state.items.size() == 2:
		await get_tree().process_frame
	var picked: Dictionary = {}
	var found: bool = false
	for item: Dictionary in world.inventory_endpoint.state.items:
		if item.uid == uid:
			found = true
			picked = item
	if not found:
		fail("ground UID not persisted")
		return
	var inventory: SpikeInventory3D = world.inventory_endpoint
	var comparison: Dictionary = inventory.weapon_comparison(picked)
	if comparison.attack != 10 + int(picked.stats.attack) or comparison.delta != comparison.attack - 27:
		fail("picked item comparison")
		return
	await action("equip", picked)
	if inventory.state.equipment.weapon != uid or inventory.state.stats.attack != comparison.attack:
		fail("picked item exact equip and stats")
		return
	var persisted: Dictionary = inventory.state.duplicate(true)
	while int(combat.state.progression.experience) == 0 and int(combat.state.progression.level) == 1:
		await get_tree().process_frame
	var earned_progression: Dictionary = combat.state.progression.duplicate(true)
	var currency: SpikeCurrency3D = world.currency_endpoint
	# Walk into the drop to exercise production auto-pickup through movement RPCs.
	while currency.state.is_empty() or int(currency.state.balance) == 0:
		if not currency.state.is_empty() and not currency.state.drops.is_empty():
			var first_drop: Dictionary = currency.state.drops.values()[0]
			await face_or_approach(first_drop.position, 0.7)
		else:
			await get_tree().process_frame
	var earned_yang: int = int(currency.state.balance)
	Client.close_connection()
	Client.instance_manager.teardown()
	world = null
	await get_tree().create_timer(1.5).timeout
	identity.erase("data")
	var characters: Dictionary = await api(GatewayAPI.world_characters(), identity)
	if characters.is_empty(): return
	handoff = await api(GatewayAPI.world_enter(), {"t-id": session.session_id, "a-u": session.name, "w-id": world_id, "c-id": int(characters.keys()[0])})
	if handoff.is_empty(): return
	Client.connect_to_server(handoff.address, handoff.port, handoff["auth-token"])
	await wait_inventory()
	if world.inventory_endpoint.state != persisted:
		fail("picked item/equip changed after relog")
		return
	while world.combat_endpoint.state.is_empty(): await get_tree().process_frame
	if world.combat_endpoint.state.progression != earned_progression:
		fail("XP and level changed after relog")
		return
	while world.currency_endpoint.state.is_empty(): await get_tree().process_frame
	if int(world.currency_endpoint.state.balance) != earned_yang:
		fail("Yang changed after logout/relog")
		return
	print("PVE_SESSION_OK: gateway/master/world, combat, pickup/equip UID, XP, level and Yang after relog")
	Client.close_connection()
	get_tree().quit()
