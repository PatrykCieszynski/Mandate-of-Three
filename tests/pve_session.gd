extends "res://tests/items_session.gd"
## One real gateway/master/world login, combat, pickup and relog. This creates a
## local guest character; run against an otherwise quiet normal Spike instance.

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
	while combat.state.is_empty() or combat.state.drops.is_empty():
		attack_sequence += 1
		combat.request_attack.rpc_id(1, attack_sequence, 1)
		await get_tree().create_timer(0.65).timeout
		if attack_sequence == 3: await capture("pve-combat-preview.png")
	if combat.mob_state != "DEAD" or combat.state.drops.size() != 1:
		fail("mob death with one ground item")
		return
	if world.inventory_endpoint.state.items.size() != 2:
		fail("item granted before pickup")
		return
	await capture("pve-loot-preview.png")
	var uid: String = combat.state.drops.keys()[0]
	combat.request_pickup.rpc_id(1, uid)
	while world.inventory_endpoint.state.items.size() == 2:
		await get_tree().process_frame
	var persisted: Dictionary = world.inventory_endpoint.state.duplicate(true)
	var found: bool = false
	for item: Dictionary in persisted.items:
		found = found or item.uid == uid
	if not found:
		fail("ground UID not persisted")
		return
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
	print("PVE_SESSION_OK: gateway/master/world, combat, ground item, pickup, exact UID after relog")
	Client.close_connection()
	get_tree().quit()
