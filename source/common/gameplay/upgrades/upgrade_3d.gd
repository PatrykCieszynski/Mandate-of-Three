class_name Upgrade3D
extends Node
signal state_changed(snapshot: Dictionary)
signal operation_finished(command_id: String, result: Dictionary)
var state: Dictionary = {"active":false}
var _world: Node3D
var _selected: Dictionary[int, String] = {}
var _last_upgrade: Dictionary[int, int] = {}
var _published: Dictionary[int, Dictionary] = {}

func _ready() -> void:
	_world = get_parent()
	_world.npc_endpoint.context_changed.connect(func(peer_id: int) -> void: publish(peer_id))

func authorization(peer_id: int, instance_id: String, service_id: StringName) -> Dictionary:
	var body: Node3D = _world.characters.get(peer_id)
	if body is SpikeCharacter3D and not body.alive: return {"ok":false,"error":"dead"}
	var result: Dictionary = _world.npc_endpoint.resolve_npc_service(peer_id,instance_id,service_id,NpcServiceDefinition.Kind.UPGRADE)
	if not result.ok: return result
	if _world.npc_endpoint.contexts[peer_id].selected_service_id != service_id: return {"ok":false, "error":"no_interaction"}
	var recipe: UpgradeDefinition = UpgradeDefinitions.get_definition(result.content_ref)
	if recipe == null or not recipe.validation_errors().is_empty(): return {"ok":false, "error":"invalid_definition"}
	return {"ok":true, "recipe":recipe}

func select_for_peer(peer_id: int, instance_id: String, service_id: StringName, uid: String, revision: int) -> Dictionary:
	var auth: Dictionary = authorization(peer_id,instance_id,service_id)
	if not auth.ok: return auth
	var player: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	if player == null: return {"ok":false,"error":"unknown_player"}
	var candidate: Dictionary = UpgradeStoreSqlite.new(WorldServer.curr.database.db).candidate(player.player_id,uid,revision,auth.recipe)
	if not candidate.ok: return candidate
	_selected[peer_id] = uid # Selection never mutates placement or consumes anything.
	return {"ok":true}

func upgrade_for_peer(peer_id: int, instance_id: String, service_id: StringName, uid: String, revision: int, now: int) -> Dictionary:
	if now - _last_upgrade.get(peer_id,-1000) < 100: return {"ok":false,"error":"too_fast"}
	_last_upgrade[peer_id] = now
	var auth: Dictionary = authorization(peer_id,instance_id,service_id)
	if not auth.ok: return {"ok":false,"error":auth.error}
	var player: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	if player == null: return {"ok":false,"error":"unknown_player"}
	return WorldServer.curr.database.upgrade_item(player.player_id,auth.recipe,uid,revision)

func snapshot_for_peer(peer_id: int) -> Dictionary:
	var context: NpcInteractionContext = _world.npc_endpoint.contexts.get(peer_id)
	if context == null:
		_selected.erase(peer_id)
		return {"active":false}
	var auth: Dictionary = authorization(peer_id,context.npc_instance_id,context.selected_service_id)
	if not auth.ok:
		_selected.erase(peer_id)
		return {"active":false}
	var recipe: UpgradeDefinition = auth.recipe
	var player: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	if player == null: return {"active":false}
	var inventory: Dictionary = _world.inventory_endpoint._store().inventory(player.player_id)
	if not inventory.ok: return {"active":false}
	var owned: int = 0
	var candidate: Dictionary = {}
	for item: Dictionary in inventory.items:
		if item.location != "bag": continue
		if item.definition_id == str(recipe.material_definition_id) and item.upgrade_level == 0: owned += int(item.amount)
		if item.uid == _selected.get(peer_id,"") and item.definition_id == str(recipe.item_definition_id):
			candidate = {"id":item.uid,"revision":item.revision,"level":item.upgrade_level,"attack":int(item.stats.get("attack",0)),"nextAttack":int(item.stats.get("attack",0)) + int(ItemDefinitions.get_definition(recipe.item_definition_id).stats_per_upgrade.get(&"attack",0))}
	var material: ItemDefinition = ItemDefinitions.get_definition(recipe.material_definition_id)
	return {"active":true,"npcInstanceId":context.npc_instance_id,"serviceId":str(context.selected_service_id),"upgradeId":str(recipe.upgrade_id),"itemDefinitionId":str(recipe.item_definition_id),"itemName":ItemDefinitions.get_definition(recipe.item_definition_id).item_name,"fromLevel":recipe.from_level,"toLevel":recipe.to_level,"yangCost":recipe.yang_cost,"materialDefinitionId":str(recipe.material_definition_id),"materialName":material.item_name,"materialAmount":recipe.material_amount,"materialOwned":owned,"successRate":recipe.success_rate,"candidate":candidate}

func publish(peer_id: int) -> void:
	if not GameMode.is_world_server(): return
	var snapshot: Dictionary = snapshot_for_peer(peer_id)
	if _world.characters.has(peer_id) and multiplayer.has_multiplayer_peer() and _published.get(peer_id,{}) != snapshot:
		_published[peer_id] = snapshot.duplicate(true)
		receive_state.rpc_id(peer_id,snapshot)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_upgrade(action: String, instance_id: String, service_id: String, uid: String, revision: int, command_id: String) -> void:
	if not GameMode.is_world_server() or command_id.length() > 80 or instance_id.length() > 80 or service_id.length() > 64 or not ItemInstance.valid_uid(uid) or revision < 0: return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer_id): return
	var result: Dictionary
	match action:
		"select": result = select_for_peer(peer_id,instance_id,StringName(service_id),uid,revision)
		"upgrade": result = upgrade_for_peer(peer_id,instance_id,StringName(service_id),uid,revision,Time.get_ticks_msec())
		_: result = {"ok":false,"error":"request"}
	# Selection changes only the quote; a stale revision also repairs Inventory.
	if action == "upgrade":
		_world.inventory_endpoint._send_state(peer_id)
		_world.currency_endpoint._send_snapshot(peer_id)
	elif result.get("error","") == "stale":
		_world.inventory_endpoint._send_state(peer_id)
	publish(peer_id)
	receive_operation.rpc_id(peer_id,command_id,{"ok":true} if result.ok else {"ok":false,"error":result.error})

func remove_peer(peer_id: int) -> void:
	_selected.erase(peer_id)
	_published.erase(peer_id)
	_last_upgrade.erase(peer_id)

@rpc("authority", "call_remote", "reliable", 1)
func receive_state(snapshot: Dictionary) -> void:
	if GameMode.is_world_server(): return
	state = snapshot.duplicate(true)
	state_changed.emit(state)

@rpc("authority", "call_remote", "reliable", 1)
func receive_operation(command_id: String, result: Dictionary) -> void:
	if not GameMode.is_world_server(): operation_finished.emit(command_id,result)
