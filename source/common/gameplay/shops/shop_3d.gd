class_name Shop3D
extends Node
signal state_changed(snapshot: Dictionary)
signal operation_finished(command_id: String, result: Dictionary)
var state: Dictionary = {"active":false}
var _world: Node3D
var _open: Dictionary[int, Dictionary] = {}
var _published: Dictionary[int, Dictionary] = {}
var _last_buy: Dictionary[int, int] = {}

func _ready() -> void:
	_world = get_parent()
	_world.npc_endpoint.context_changed.connect(_context_changed)

func _authorization(peer_id: int, instance_id: String, service_id: StringName) -> Dictionary:
	var result: Dictionary = _world.npc_endpoint.resolve_npc_service(peer_id, instance_id, service_id, NpcServiceDefinition.Kind.SHOP)
	if not result.ok: return {"ok":false, "error":result.error}
	var context: NpcInteractionContext = _world.npc_endpoint.contexts[peer_id]
	if context.selected_service_id != service_id: return {"ok":false, "error":"no_interaction"}
	var shop: ShopDefinition = ShopDefinitions.get_definition(result.content_ref)
	if shop == null or not shop.validation_errors().is_empty(): return {"ok":false, "error":"invalid_definition"}
	return {"ok":true, "shop":shop}

func open_for_peer(peer_id: int, instance_id: String, service_id: StringName) -> Dictionary:
	var result: Dictionary = _authorization(peer_id, instance_id, service_id)
	if not result.ok: return result
	_open[peer_id] = {"instance":instance_id, "service":service_id}
	return {"ok":true}

func buy_for_peer(peer_id: int, instance_id: String, service_id: StringName, offer_id: StringName, position: int, now: int) -> Dictionary:
	if now - _last_buy.get(peer_id, -1000) < 100: return {"ok":false, "error":"too_fast"}
	_last_buy[peer_id] = now
	var authorization: Dictionary = _authorization(peer_id, instance_id, service_id)
	if not authorization.ok: return authorization
	if WorldServer.curr == null or WorldServer.curr.database == null: return {"ok":false, "error":"storage"}
	var player: PlayerResource = WorldServer.curr.connected_players.get(peer_id)
	if player == null: return {"ok":false, "error":"unknown_player"}
	return WorldServer.curr.database.purchase_shop_offer(player.player_id, authorization.shop, offer_id, position)

func snapshot_for_peer(peer_id: int) -> Dictionary:
	if not _open.has(peer_id): return {"active":false}
	var opening: Dictionary = _open[peer_id]
	var result: Dictionary = _authorization(peer_id, opening.instance, opening.service)
	if not result.ok:
		_open.erase(peer_id)
		return {"active":false}
	var shop: ShopDefinition = result.shop
	var offers: Array[Dictionary] = []
	for offer: ShopOfferDefinition in shop.offers:
		var definition: ItemDefinition = ItemDefinitions.get_definition(offer.item_definition_id)
		offers.append({"offerId":str(offer.offer_id), "itemDefinitionId":str(offer.item_definition_id), "name":definition.item_name, "iconId":str(definition.icon_id), "height":definition.inventory_height, "quantity":offer.quantity, "price":offer.price})
	return {"active":true, "npcInstanceId":opening.instance, "serviceId":str(opening.service), "shopId":str(shop.shop_id), "name":shop.display_name, "currency":"yang", "offers":offers}

func _context_changed(peer_id: int) -> void:
	_publish(peer_id)

func _publish(peer_id: int) -> void:
	var snapshot: Dictionary = snapshot_for_peer(peer_id)
	if GameMode.is_world_server() and _world.characters.has(peer_id) and multiplayer.has_multiplayer_peer() and _published.get(peer_id, {}) != snapshot:
		_published[peer_id] = snapshot.duplicate(true)
		receive_shop.rpc_id(peer_id, snapshot)

@rpc("any_peer", "call_remote", "reliable", 1)
func request_shop(action: String, instance_id: String, service_id: String, offer_id: String, position: int, command_id: String) -> void:
	if not GameMode.is_world_server() or command_id.length() > 80 or instance_id.length() > 80 or service_id.length() > 64 or offer_id.length() > 64: return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer_id): return
	var result: Dictionary
	match action:
		"open": result = open_for_peer(peer_id, instance_id, StringName(service_id))
		"buy": result = buy_for_peer(peer_id, instance_id, StringName(service_id), StringName(offer_id), position, Time.get_ticks_msec())
		_: result = {"ok":false, "error":"request"}
	if action == "buy" and result.ok:
		_world.inventory_endpoint._send_state(peer_id)
		_world.currency_endpoint._send_snapshot(peer_id)
	_publish(peer_id)
	# Browser command results use the existing narrow ok/error contract.
	receive_operation.rpc_id(peer_id, command_id, {"ok":true} if result.ok else {"ok":false, "error":result.error})

func remove_peer(peer_id: int) -> void:
	_open.erase(peer_id)
	_published.erase(peer_id)
	_last_buy.erase(peer_id)

@rpc("authority", "call_remote", "reliable", 1)
func receive_shop(snapshot: Dictionary) -> void:
	if GameMode.is_world_server(): return
	state = snapshot.duplicate(true)
	state_changed.emit(state)

@rpc("authority", "call_remote", "reliable", 1)
func receive_operation(command_id: String, result: Dictionary) -> void:
	if not GameMode.is_world_server(): operation_finished.emit(command_id, result)
