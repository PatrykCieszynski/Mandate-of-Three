class_name Shop3D
extends Node
var services: MandateWorldServices
signal state_changed(snapshot: Dictionary)
signal operation_finished(command_id: String, result: Dictionary)
var state: Dictionary = {"active":false}
var _world: Node3D
var _open: Dictionary[int, Dictionary] = {}
var _published: Dictionary[int, Dictionary] = {}
var _last_buy: Dictionary[int, int] = {}
var _last_receipt: Dictionary[int, int] = {}
var _postgres: RefCounted
var _vendor: RefCounted
signal vendor_result(request_id: String, result: Dictionary)

func _ready() -> void:
	_world = get_parent()
	_world.npc_endpoint.context_changed.connect(_context_changed)
	if GameMode.is_world_server() and services.npc_runtime()!=null:
		_postgres=preload("res://source/common/gameplay/world3d/endpoints/npc_postgres_adapter.gd").new(self,services.npc_runtime(),"buy")
		_vendor=preload("res://source/common/gameplay/world3d/endpoints/npc_postgres_adapter.gd").new(self,services.npc_runtime(),"sell")

func _exit_tree() -> void:
	if _postgres!=null: _postgres.dispose()
	if _vendor!=null: _vendor.dispose()

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

func buy_for_peer(peer_id: int, instance_id: String, service_id: StringName, offer_id: StringName, position: int, now: int, operation_id: String = "") -> Dictionary:
	if not services.mutations_allowed(peer_id): return {"ok":false,"error":"transfer_pending"}
	if now - _last_buy.get(peer_id, -1000) < 100: return {"ok":false, "error":"too_fast"}
	_last_buy[peer_id] = now
	var authorization: Dictionary = _authorization(peer_id, instance_id, service_id)
	if not authorization.ok: return authorization
	if not services.available() or services.economy() == null: return {"ok":false, "error":"storage"}
	var player: PlayerResource = services.player_for_peer(peer_id)
	if player == null: return {"ok":false, "error":"unknown_player"}
	var operation: Variant = services.economy().purchase_shop_operation(player.player_id, authorization.shop, offer_id, position, operation_id)
	if operation.new_commit:
		# The database operation has committed and accepted wallet RAM.
		# Prepare equipment/cache before either endpoint sees a change fact.
		_world.inventory_endpoint.accept_committed_change(peer_id)
		_world.currency_endpoint.accept_committed_change(peer_id)
	elif operation.receipt_replay:
		_world.inventory_endpoint.resynchronize(peer_id)
		_world.currency_endpoint.resynchronize(peer_id)
	return operation.response()

func receipt_for_peer(peer_id: int, operation_id: String, now: int) -> Dictionary:
	if now - _last_receipt.get(peer_id, -1000) < 100: return {"ok":false,"error":"too_fast"}
	_last_receipt[peer_id] = now
	var player: PlayerResource = services.player_for_peer(peer_id)
	if player == null: return {"ok":false,"error":"unknown_player"}
	if services.economy() == null: return {"ok":false,"error":"storage"}
	var operation: Variant = services.economy().shop_purchase_receipt(player.player_id, operation_id)
	var result: Variant = operation.response()
	if result.ok:
		_world.inventory_endpoint.resynchronize(peer_id)
		_world.currency_endpoint.resynchronize(peer_id)
	return result

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
func request_shop(action: String, instance_id: String, service_id: String, offer_id: String, position: int, command_id: String, operation_id: String = "") -> void:
	if not GameMode.is_world_server() or command_id.length() > 80 or instance_id.length() > 80 or service_id.length() > 64 or offer_id.length() > 64 or operation_id.length() > 96: return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer_id): return
	if _postgres!=null and action in ["buy","receipt"]:
		var now: int=Time.get_ticks_msec()
		if _postgres.busy(peer_id) or now-_last_buy.get(peer_id,-1000)<100:
			receive_operation.rpc_id(peer_id,command_id,{"ok":false,"error":"storage"})
			return
		_last_buy[peer_id]=now
		if action=="receipt": _postgres.receipt(peer_id,command_id,operation_id)
		else:
			var auth:=_authorization(peer_id,instance_id,StringName(service_id))
			if not auth.ok or services.transfer_pending(peer_id):
				receive_operation.rpc_id(peer_id,command_id,{"ok":false,"error":auth.get("error","transfer_pending")})
				return
			_postgres.buy(peer_id,command_id,operation_id,auth.shop,StringName(offer_id),position)
		return
	var result: Dictionary
	match action:
		"open": result = open_for_peer(peer_id, instance_id, StringName(service_id))
		"receipt": result = receipt_for_peer(peer_id, operation_id, Time.get_ticks_msec())
		"buy": result = buy_for_peer(peer_id, instance_id, StringName(service_id), StringName(offer_id), position, Time.get_ticks_msec(), operation_id)
		_: result = {"ok":false, "error":"request"}
	_publish(peer_id)
	# Browser command results use the existing narrow ok/error contract.
	receive_operation.rpc_id(peer_id, command_id, {"ok":true} if result.ok else {"ok":false, "error":result.error})

func remove_peer(peer_id: int) -> void:
	if _postgres!=null: _postgres.remove_peer(peer_id)
	if _vendor!=null: _vendor.remove_peer(peer_id)
	_open.erase(peer_id)
	_published.erase(peer_id)
	_last_buy.erase(peer_id)
	_last_receipt.erase(peer_id)

@rpc("authority", "call_remote", "reliable", 1)
func receive_shop(snapshot: Dictionary) -> void:
	if GameMode.is_world_server(): return
	state = snapshot.duplicate(true)
	state_changed.emit(state)

@rpc("authority", "call_remote", "reliable", 1)
func receive_operation(command_id: String, result: Dictionary) -> void:
	if not GameMode.is_world_server(): operation_finished.emit(command_id, result)

## Backend contract only. Basket references do not leave authoritative Inventory.
## Fresh quote/sell reauthorize NPC/service/range; recovery needs current session
## authority but can read a receipt after leaving the vendor.
@rpc("any_peer", "call_remote", "reliable", 1)
func request_vendor(action: String, instance_id: String, service_id: String, payload: Dictionary, request_id: String) -> void:
	if not GameMode.is_world_server() or request_id.is_empty() or request_id.length()>80 or instance_id.length()>80 or service_id.length()>64: return
	var peer: int=multiplayer.get_remote_sender_id()
	if not _world.characters.has(peer): return
	if _vendor==null:
		receive_vendor.rpc_id(peer,request_id,{"ok":false,"error":"unsupported_backend"});return
	if action not in ["quote","sell","receipt"]: return
	var valid: bool=false
	if action=="quote": valid=payload.size()==1 and payload.get("items") is Array and not VendorResolver.cart(payload.items).is_empty()
	elif action=="sell": valid=payload.size()==2 and payload.get("quote_id") is String and ItemInstance.valid_uid(payload.quote_id) and payload.get("command_id") is String and _vendor_command_id(payload.command_id)
	else: valid=payload.size()==1 and payload.get("command_id") is String and _vendor_command_id(payload.command_id)
	if not valid:
		receive_vendor.rpc_id(peer,request_id,{"ok":false,"error":"request"});return
	if _vendor.busy(peer) or Time.get_ticks_msec()-_last_buy.get(peer,-1000)<100:
		receive_vendor.rpc_id(peer,request_id,{"ok":false,"error":"storage"});return
	_last_buy[peer]=Time.get_ticks_msec()
	if action=="receipt":
		_vendor.receipt(peer,request_id,payload.command_id);return
	var auth:=_authorization(peer,instance_id,StringName(service_id))
	if not auth.ok or services.transfer_pending(peer):
		receive_vendor.rpc_id(peer,request_id,{"ok":false,"error":auth.get("error","transfer_pending")});return
	if action=="quote": receive_vendor.rpc_id(peer,request_id,services.npc_runtime().quote(peer,str(get_instance_id())+":"+instance_id,service_id,payload.items))
	else: _vendor.sell(peer,request_id,payload.command_id,payload.quote_id,str(get_instance_id())+":"+instance_id,service_id)

@rpc("authority", "call_remote", "reliable", 1)
func receive_vendor(request_id: String, result: Dictionary) -> void:
	if not GameMode.is_world_server(): vendor_result.emit(request_id,result)

static func _vendor_command_id(value: String) -> bool:
	if value.is_empty() or value.length()>96: return false
	for letter: String in value:
		if not "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:".contains(letter): return false
	return true
