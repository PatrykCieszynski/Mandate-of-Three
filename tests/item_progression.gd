extends "res://tests/pve_network.gd"
## Production combat, ground pickup and equip RPCs with a deterministic loot
## roll in the server fixture. SQLite is isolated; no live accounts are changed.

var improved: bool = false
var committed_inventory_changes: int = 0

class CountingItemStore extends ItemStoreSqlite:
	var inventory_reads: int = 0
	func inventory(owner_id: int) -> Dictionary:
		inventory_reads += 1
		return super.inventory(owner_id)

@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, uid: String) -> void:
	if GameMode.is_world_server(): return
	phase_name = command
	drop_uid = uid
	attempted = false
	if command == "DONE":
		check(saw_damage and saw_death and saw_loot, "both clients observe fight/death/loot")
		check(world.combat_endpoint.state.drops.is_empty(), "ground item disappears on both clients")
		check(world.inventory_endpoint.state.items.size() == (3 if improved else 2), "private item snapshot")
		if improved:
			check(world.inventory_endpoint.state.equipment.weapon == drop_uid and world.inventory_endpoint.state.stats.attack == 29, "picked UID stays equipped")
		if not failed:
			print("PROGRESSION_CLIENT_OK: ", client_number, " comparison, pickup, equip and private replication")
			finished.rpc_id(1)
			await get_tree().create_timer(0.5).timeout
			peer.close()
			get_tree().quit()

func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	var hero: int = world.characters.keys()[0]
	var other: int = world.characters.keys()[1]
	var owner_id: int = server.connected_players[hero].player_id
	var combat: CombatEndpoint3D = world.combat_endpoint
	var store := CountingItemStore.new(db)
	server.database.item_store = store
	var inventory: InventoryEndpoint3D = world.inventory_endpoint
	inventory.inventory_changed.connect(func(_owner_id: int) -> void: committed_inventory_changes += 1)
	for dog: MobActor3D in world.mob_system.mobs.values():
		dog.ai_enabled = false
		if dog.mob_id != 1:
			dog.ai_state = MobState.Value.DISABLED
			dog.collision_layer = 0
	world.characters[hero].position = Vector3(0, 0, 3)
	world.characters[hero].rotation.y = 0
	world.characters[other].position = Vector3(-12, 0, 12)
	world.mob_system.mobs[1].position = Vector3(0, 0, 1.4)
	await get_tree().create_timer(0.2).timeout
	set_phase("WEAK", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and store.inventory(owner_id).stats.attack == 23, "starter sword equipped through RPC")
	check(server.runtime_attack(owner_id) == 23, "equip updates authoritative runtime attack")
	var older_equipment := store.inventory(owner_id)
	store.inventory_reads = 0
	set_phase("BASELINE", hero)
	await wait_until(func() -> bool: return world.mob_system.mobs[1].hp < 120)
	check(world.mob_system.mobs[1].hp == 97, "baseline first-stage damage is 23")
	# Critical hot-path invariant; damage alone cannot reveal per-swing SQL reads.
	check(store.inventory_reads == 0, "swing never reads SQLite inventory")
	set_phase("WAIT")
	await get_tree().create_timer(0.5).timeout
	set_phase("FIGHT", hero)
	await wait_until(func() -> bool: return world.mob_system.mobs[1].ai_state == MobState.Value.DEAD)
	world.mob_system.mobs[1].dead_until_ms = Time.get_ticks_msec() + 60000
	for ticket: Dictionary in world.mob_system.packs[world.mob_system.mobs[1].pack_instance_id].replacements: ticket.at = Time.get_ticks_msec() + 60000
	set_phase("WAIT")
	check(world.ground_loot.drops.size() == 1 and store.inventory(owner_id).items.size() == 2, "mob creates ground loot, no automatic grant")
	drop_uid = world.ground_loot.drops.keys()[0]
	# Fix only the fixture's roll to guarantee the better-weapon branch. The
	# production random range, receipt, pickup and equip code remain unchanged.
	world.ground_loot.drops[drop_uid].affixes = [{"stat":"attack","value":9}]
	await get_tree().create_timer(0.2).timeout
	set_phase("PICKUP", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok and replies[hero].uid == drop_uid, "real pickup claims exact ground UID")
	check(store.inventory(owner_id).stats.attack == 23 and store.inventory(owner_id).items.size() == 3, "pickup does not equip automatically")
	set_phase("COMPARE", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(replies[hero].ok, "weapon comparison, picked item and immutable snapshot")
	check(db.query("CREATE TEMP TRIGGER fail_runtime_equip BEFORE INSERT ON item_custody BEGIN SELECT RAISE(ABORT,'intentional runtime equip failure'); END;"), "failed equip fixture")
	var before_failed_notifications := committed_inventory_changes
	set_phase("FAIL_EQUIP", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	check(not replies[hero].ok and server.runtime_attack(owner_id) == 23, "rollback leaves runtime attack unchanged")
	check(committed_inventory_changes==before_failed_notifications,"rolled-back equip only resynchronizes; it emits no committed-change fact")
	check(db.query("DROP TRIGGER fail_runtime_equip;"), "remove equip fault")
	await get_tree().create_timer(0.15).timeout
	set_phase("BETTER", hero)
	await wait_until(func() -> bool: return replies.has(hero))
	var equipped: Dictionary = store.inventory(owner_id)
	check(replies[hero].ok and equipped.stats.attack == 29 and equipped.equipment.weapon == drop_uid, "picked weapon raises authoritative attack")
	check(server.runtime_attack(owner_id) == 29, "committed swap updates runtime stats")
	check(not server.update_runtime_equipment(owner_id,older_equipment) and server.runtime_attack(owner_id)==29,"late older snapshot cannot restore prior weapon stats")
	check(not server.update_runtime_equipment(owner_id,{"ok":false,"error":"storage"}) and server.runtime_attack(owner_id)==-1,"failed refresh gates dependent combat")
	check(not server.update_runtime_equipment(owner_id,older_equipment) and server.runtime_attack(owner_id)==-1,"failure retains watermark and cannot be repaired by older state")
	check(server.update_runtime_equipment(owner_id,equipped) and server.runtime_attack(owner_id)==29,"same current revision can rehydrate invalidated cache")
	var duplicate := equipped.duplicate(true)
	duplicate.stats.attack = 999
	check(not server.update_runtime_equipment(owner_id,duplicate) and server.runtime_attack(owner_id)==29,"duplicate revision does not replace accepted combat inputs")
	check(store.inventory(server.connected_players[other].player_id).items.size() == 2, "other player receives no inventory")
	await get_tree().create_timer(1.2).timeout
	var old_dog: MobActor3D = world.mob_system.mobs[1]
	var pack: MobPackRuntime = world.mob_system.packs[old_dog.pack_instance_id]
	pack.replacements.clear()
	world.mob_system.remove_mob(1)
	var replacement := world.mob_system.spawn_mob(old_dog.definition,Vector3(0,0,1.4),pack)
	replacement.ai_enabled = false
	replacement.position = Vector3(0, 0, 1.4)
	await get_tree().create_timer(0.1).timeout
	store.inventory_reads = 0
	set_phase("IMPROVED", hero)
	await wait_until(func() -> bool: return replacement.hp < 120)
	check(combat.attacks.attack_runtime(hero).display_combo_step == 1 and replacement.hp == 91, "same first-stage attack now deals 29 instead of 23")
	check(store.inventory_reads == 0, "improved attack also uses RAM only")
	set_phase("WAIT")
	check(db.close_db() and db.open_db(), "reopen SQLite")
	check(store.initialize_character(owner_id).ok and store.inventory(owner_id) == equipped, "exact UID, roll, placement and revision survive reopen/reinitialization")
	server.runtime_equipment.erase(owner_id)
	world.inventory_endpoint.initialize_peer(hero)
	check(server.runtime_attack(owner_id) == 29 and server.runtime_equipment[owner_id].equipment.weapon == drop_uid, "enter-world restores correct runtime stats from persisted equip")
	await get_tree().create_timer(0.3).timeout
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	if not failed:
		print("PROGRESSION_SERVER_OK: kill, ground roll, pickup, compare, equip, damage 23 -> 29, exact persistence")
		peer.close()
		db.close_db()
		get_tree().quit()

func equip_and_report(item: Dictionary) -> void:
	var inventory: InventoryEndpoint3D = world.inventory_endpoint
	inventory.request_equipment.rpc_id(1, "equip", str(item.uid), int(item.revision), "", -1, "progression-"+Crypto.new().generate_random_bytes(8).hex_encode())
	await inventory.state_changed
	report.rpc_id(1, {"ok": not inventory.state.has("error") and inventory.state.equipment.get("weapon", "") == item.uid})

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > 35:
		check(false, "progression timeout phase=" + phase_name)
		return
	if GameMode.is_world_server() or world == null or world.combat_endpoint.state.is_empty(): return
	if not ready_peers.has(world.local_peer):
		ready_peers[world.local_peer] = true
		register_ready.rpc_id(1)
	var combat: CombatEndpoint3D = world.combat_endpoint
	var inventory: InventoryEndpoint3D = world.inventory_endpoint
	saw_damage = saw_damage or (world.mob_system.mobs.has(1) and world.mob_system.mobs[1].hp < 120)
	saw_death = saw_death or (world.mob_system.mobs.has(1) and world.mob_system.mobs[1].ai_state == MobState.Value.DEAD)
	saw_loot = saw_loot or not combat.state.drops.is_empty()
	accumulator += delta
	if phase_name == "FIGHT" and accumulator >= 0.05:
		accumulator = 0
		sequence += 1
		combat.request_attack.rpc_id(1, sequence)
	if attempted: return
	if phase_name in ["BASELINE", "IMPROVED"]:
		attempted = true
		sequence += 1
		combat.request_attack.rpc_id(1, sequence)
	elif phase_name == "WEAK":
		attempted = true
		for item: Dictionary in inventory.state.items:
			if item.stats.attack == 13:
				equip_and_report(item)
				break
	elif phase_name == "PICKUP":
		attempted = true
		check(int(combat.state.drops[drop_uid].weapon_attack) == 19, "ground label describes rolled weapon")
		combat.request_pickup.rpc_id(1, drop_uid)
	elif phase_name == "COMPARE":
		# Pickup feedback and the inventory arrive on different reliable channels.
		if inventory.state.items.size() != 3: return
		attempted = true
		var before: Dictionary = inventory.state.duplicate(true)
		var ok: bool = inventory.state.items.any(func(i: Dictionary) -> bool: return i.uid == drop_uid and i.stats.attack == 19)
		for item: Dictionary in inventory.state.items:
			var preview: Dictionary = inventory.weapon_comparison(item)
			if item.uid == drop_uid:
				ok = ok and preview.attack == 29 and preview.delta == 6
			elif item.location == "equipment":
				ok = ok and preview.attack == 23 and preview.delta == 0
		ok = ok and inventory.state == before
		report.rpc_id(1, {"ok": ok})
	elif phase_name in ["BETTER", "FAIL_EQUIP"]:
		attempted = true
		if phase_name == "BETTER": improved = true
		for item: Dictionary in inventory.state.items:
			if item.uid == drop_uid:
				equip_and_report(item)
				break
