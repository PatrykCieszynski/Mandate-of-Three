class_name MarketEndpoint3D
extends Node
var services: MandateWorldServices
signal state_changed(snapshot: Dictionary)
signal operation_finished(request_id: String, result: Dictionary)
var state: Dictionary = {}
var _world: GameWorld3D
var _rate: Dictionary = {}
var _economy: WorldDatabase
func _ready() -> void:
	_world=get_parent()
	if GameMode.is_world_server() and services.available():
		_economy=services.economy()
		if _economy!=null: _economy.market_account_changed.connect(_account_changed)
func _exit_tree() -> void:
	if is_instance_valid(_economy) and _economy.market_account_changed.is_connected(_account_changed): _economy.market_account_changed.disconnect(_account_changed)
func _account_changed(account_id: int) -> void:
	# World-scoped DB facts reach every instance, not just the requesting map.
	for peer: int in _world.characters:
		if _economy.wallet_account_id(_owner(peer))==account_id:
			_publish(peer);_publish_exchange(peer)
			_world.currency_endpoint.accept_committed_change(peer)

static func integer(value: Variant, maximum: int = MarketRequestRules.MAX_YANG) -> bool:
	return MarketRequestRules.integer(value,maximum)

static func valid(action: String, p: Dictionary) -> bool:
	if action == "open": return p.is_empty()
	if not p.get("command_id") is String or p.command_id.is_empty() or p.command_id.length()>96: return false
	var fields: Array
	match action:
		"order": return MarketRequestRules.valid_order(p)
		"cancel_order": fields = ["command_id","order_id","revision"]
		"deposit": fields = ["command_id","uid","revision","amount","source"]
		"withdraw": fields = ["command_id","asset_id","amount","destination"]
		"list": fields = ["command_id","uid","revision","position","price"]
		"buy": fields = ["command_id","shop_id","offer_id","revision","price"]
		"edit": fields = ["command_id","offer_id","revision","position","price"]
		"cancel": fields = ["command_id","offer_id","revision"]
		"claim": fields = ["command_id","uid","revision"]
		"configure": fields = ["command_id","revision","name","status"]
		"receipt": fields = ["command_id"]
		_: return false
	if p.size()!=fields.size() or not p.has_all(fields): return false
	if p.has("order_id") and (not p.order_id is String or not ItemInstance.valid_uid(p.order_id)): return false
	if p.has("amount") and (not integer(p.amount,200) or p.amount<=0): return false
	if action=="deposit" and p.source not in ["bag","account_storage"]: return false
	if action=="withdraw" and (not p.asset_id is String or MarketRequestRules.asset_definition(p.asset_id)==null or p.destination not in ["bag","claim"]): return false
	if p.has("shop_id") and (not integer(p.shop_id) or p.shop_id<=0): return false
	if p.has("uid") and (not p.uid is String or not ItemInstance.valid_uid(p.uid)): return false
	if p.has("offer_id") and (not p.offer_id is String or not ItemInstance.valid_uid(p.offer_id)): return false
	if p.has("revision") and not integer(p.revision): return false
	if p.has("position") and not integer(p.position,39): return false
	if p.has("price") and (not integer(p.price) or p.price<=0): return false
	if action=="configure" and (not p.name is String or p.name.length()>40 or p.name.strip_edges().is_empty() or p.status not in ["active","paused"]): return false
	return true

func _owner(peer_id: int) -> int:
	var player := services.player_for_peer(peer_id)
	return player.player_id if player!=null else 0

func perform_for_peer(peer_id: int, action: String, payload: Dictionary) -> Dictionary:
	if not valid(action,payload) or not services.available() or services.economy()==null: return {"ok":false,"error":"request"}
	var owner := _owner(peer_id)
	if owner<=0: return {"ok":false,"error":"owner"}
	if action=="open": return {"ok":true}
	var result: Dictionary = services.economy().market_command(owner,action,payload)
	if result.ok and action in ["list","claim","buy","deposit","withdraw"]:
		_world.inventory_endpoint.accept_committed_change(peer_id)
	return result

func _publish(peer_id: int) -> void:
	if _owner(peer_id)<=0: return
	var snapshot: Dictionary = services.economy().market_snapshot(_owner(peer_id))
	if snapshot.ok: receive_state.rpc_id(peer_id,snapshot)

@rpc("any_peer","call_remote","reliable",1)
func request_market(action: String, payload: Dictionary, request_id: String) -> void:
	if not GameMode.is_world_server() or request_id.is_empty() or request_id.length()>80 or not _world.characters.has(multiplayer.get_remote_sender_id()): return
	var peer_id := multiplayer.get_remote_sender_id()
	if not services.available() or services.economy()==null: return
	var owner := _owner(peer_id)
	var account_id: int = services.economy().wallet_account_id(owner)
	var now := Time.get_ticks_msec()
	var rate: Dictionary = _rate.get(account_id,{"started":now,"count":0})
	if now-int(rate.started)>1000: rate = {"started":now,"count":0}
	rate.count += 1
	_rate[account_id] = rate
	var result := {"ok":false,"error":"rate_limited"} if int(rate.count)>15 else perform_for_peer(peer_id,action,payload)
	if not result.ok or action in ["open","receipt"]:
		for observer: int in _world.characters:
			if services.economy().wallet_account_id(_owner(observer))==account_id: _publish(observer)
	receive_operation.rpc_id(peer_id,request_id,{"ok":true} if result.ok else {"ok":false,"error":result.error})

func remove_peer(peer_id: int) -> void: _rate.erase("query_"+str(peer_id))

@rpc("authority","call_remote","reliable",1)
func receive_state(snapshot: Dictionary) -> void:
	state = snapshot.duplicate(true)
	state_changed.emit(state)

@rpc("authority","call_remote","reliable",1)
func receive_operation(request_id: String,result: Dictionary) -> void:
	operation_finished.emit(request_id,result)

signal query_finished(request_id: String, result: Dictionary)
static func valid_query(action: String,p: Dictionary) -> bool:
	match action:
		"exchange": return p.is_empty()
		"catalog": return p.size()==1 and p.get("query") is String and p.query.length()<=80
		"search": return MarketRequestRules.valid_search(p)
		"visit": return p.size()==1 and integer(p.get("shop_id")) and p.shop_id>0
	return false
@rpc("any_peer","call_remote","reliable",1)
func request_query(action: String,payload: Dictionary,request_id: String) -> void:
	if not GameMode.is_world_server() or request_id.is_empty() or request_id.length()>80 or not _world.characters.has(multiplayer.get_remote_sender_id()): return
	var peer_id:=multiplayer.get_remote_sender_id()
	if not services.available() or services.economy()==null: return
	# Query work is independently bounded; mutations do not consume this budget.
	var key:="query_"+str(peer_id)
	var now:=Time.get_ticks_msec()
	var rate: Dictionary=_rate.get(key,{"started":now,"count":0})
	if now-int(rate.started)>1000: rate={"started":now,"count":0}
	rate.count+=1;_rate[key]=rate
	var result: Dictionary={"ok":false,"error":"rate_limited"} if rate.count>8 else {"ok":false,"error":"request"}
	if rate.count<=8 and valid_query(action,payload): result=services.economy().market_query(_owner(peer_id),action,payload)
	receive_query.rpc_id(peer_id,request_id,result)
@rpc("authority","call_remote","reliable",1)
func receive_query(request_id: String,result: Dictionary) -> void:
	query_finished.emit(request_id,result)

signal exchange_state_changed(snapshot: Dictionary)
func _publish_exchange(peer_id: int) -> void:
	var snapshot: Dictionary=services.economy().market_query(_owner(peer_id),"exchange",{})
	if snapshot.ok: receive_exchange_state.rpc_id(peer_id,snapshot)
@rpc("authority","call_remote","reliable",1)
func receive_exchange_state(snapshot: Dictionary) -> void: exchange_state_changed.emit(snapshot)
