class_name MarketEndpoint3D
extends Node
var services: MandateWorldServices
signal state_changed(snapshot: Dictionary)
signal operation_finished(request_id: String, result: Dictionary)
var state: Dictionary = {}
var _world: GameWorld3D
var _rate: Dictionary = {}
var _economy: WorldDatabase
var observe: Callable # Opt-in snapshot/RPC enqueue wall times for load fixtures.
var _query_epochs: Dictionary = {}
var _next_query_epoch := 0
# Bounded session-local correlation history. Pending IDs are never evicted;
# recent IDs share a 64-entry history, not durable transaction receipts.
const QUERY_HISTORY_LIMIT := 64
var _query_requests: Dictionary = {}
func _ready() -> void:
	_world=get_parent()
	if GameMode.is_world_server() and services.available():
		_economy=services.economy()
		if _economy!=null: _economy.market_account_changed.connect(_account_changed)
func _exit_tree() -> void:
	if is_instance_valid(_economy) and _economy.auction_queries!=null: _economy.auction_queries.cancel_scope(str(get_instance_id())+":")
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
	return MarketRequestRules.valid_command(action, p)

func _owner(peer_id: int) -> int:
	var player := services.player_for_peer(peer_id)
	return player.player_id if player!=null else 0

func perform_for_peer(peer_id: int, action: String, payload: Dictionary) -> Dictionary:
	if action not in ["open","receipt"] and not services.mutations_allowed(peer_id): return {"ok":false,"error":"transfer_pending"}
	if not valid(action,payload) or not services.available() or services.economy()==null: return {"ok":false,"error":"request"}
	var owner := _owner(peer_id)
	if owner<=0: return {"ok":false,"error":"owner"}
	if action=="open": return {"ok":true}
	var operation: Variant = services.economy().market_operation(owner, action, payload)
	var response: Variant = operation.response()
	var recovered_receipt := action == "receipt" and bool(response.get("ok", false))
	if response.get("ok", false) and (recovered_receipt or action in ["list","cancel","claim","buy","deposit","withdraw"]):
		if operation.new_commit:
			_world.inventory_endpoint.accept_committed_change(peer_id)
		else:
			_world.inventory_endpoint.resynchronize(peer_id)
	if operation.receipt_replay or recovered_receipt:
		# Repair the caller's current views after a lost response/reconnect without
		# republishing a mutation to every account peer/instance.
		_publish(peer_id)
		_publish_exchange(peer_id)
		_world.currency_endpoint.resynchronize(peer_id)
	return response

func _publish(peer_id: int) -> void:
	if _owner(peer_id)<=0: return
	var started := Time.get_ticks_usec() if observe.is_valid() else 0
	var snapshot: Dictionary = services.economy().market_snapshot(_owner(peer_id))
	if observe.is_valid(): observe.call({"kind":"market_snapshot","cost_us":Time.get_ticks_usec()-started})
	started = Time.get_ticks_usec() if observe.is_valid() else 0
	if snapshot.ok: receive_state.rpc_id(peer_id,snapshot)
	if observe.is_valid(): observe.call({"kind":"market_rpc_enqueue","cost_us":Time.get_ticks_usec()-started})

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
	if not result.ok or action == "open":
		for observer: int in _world.characters:
			if services.economy().wallet_account_id(_owner(observer))==account_id: _publish(observer)
	receive_operation.rpc_id(peer_id,request_id,{"ok":true} if result.ok else {"ok":false,"error":result.error})

func remove_peer(peer_id: int) -> void:
	_rate.erase("query_"+str(peer_id))
	_query_epochs.erase(peer_id)
	_query_requests.erase(peer_id)
	if is_instance_valid(_economy) and _economy.auction_queries!=null: _economy.auction_queries.cancel_scope(str(get_instance_id())+":"+str(peer_id)+":")

func _query_session_valid(peer: int, owner: int, account: int, session: int, actor: int, epoch: int, economy_id: int) -> bool:
	if not is_instance_valid(_world) or not _world.characters.has(peer) or not is_instance_valid(_world.characters[peer]) or int(_query_epochs.get(peer,0))!=epoch: return false
	var economy:=services.economy()
	var player:=services.player_for_peer(peer)
	return economy!=null and economy.get_instance_id()==economy_id and economy.auction_binding_current() and player!=null and player.get_instance_id()==session and player.player_id==owner and economy.wallet_account_id(owner)==account and _world.characters[peer].get_instance_id()==actor

func _query_reply(result: Dictionary, peer: int, request_id: String) -> void:
	var ids: Dictionary=_query_requests.get(peer,{}).get("ids",{})
	if not ids.get(request_id,false): return
	ids[request_id]=false
	receive_query.rpc_id(peer,request_id,result)

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
	var player:=services.player_for_peer(peer_id)
	if player==null: return
	var session: Array=[player.get_instance_id(),_world.characters[peer_id].get_instance_id()]
	var history: Dictionary=_query_requests.get(peer_id,{})
	if history.get("session",[])!=session:
		remove_peer(peer_id)
		history={"session":session,"ids":{}};_query_requests[peer_id]=history
	var ids: Dictionary=history.ids
	# Reserve before validation/limiting, including malformed retries of an ID.
	if ids.has(request_id): return
	var economy:=services.economy()
	var pending_scope:=str(get_instance_id())+":"+str(peer_id)+":"+str(int(_query_epochs.get(peer_id,0)))+":"
	# A terminal timeout may leave SQL running even after its history entry was
	# evicted. Do not reserve that ID again until its original native slot ends.
	if economy.auction_queries!=null and economy.auction_queries.has_pending(pending_scope+request_id): return
	if ids.size()>=QUERY_HISTORY_LIMIT:
		for previous: String in ids.keys():
			if not ids[previous]: ids.erase(previous);break
		if ids.size()>=QUERY_HISTORY_LIMIT: return # Never evict an accepted pending ID.
	ids[request_id]=true
	# Query work is independently bounded; mutations do not consume this budget.
	var key:="query_"+str(peer_id)
	var now:=Time.get_ticks_msec()
	var rate: Dictionary=_rate.get(key,{"started":now,"count":0})
	if now-int(rate.started)>1000: rate={"started":now,"count":0}
	rate.count+=1;_rate[key]=rate
	var result: Dictionary={"ok":false,"error":"rate_limited"} if rate.count>8 else {"ok":false,"error":"request"}
	if rate.count<=8 and valid_query(action,payload):
		if action=="search":
			var owner:=_owner(peer_id)
			var account: int=economy.wallet_account_id(owner)
			if player==null or account<=0: result={"ok":false,"error":"owner"}
			elif economy.auction_queries==null or not economy.auction_binding_current(): result={"ok":false,"error":"storage"}
			else:
				if not _query_epochs.has(peer_id):
					_next_query_epoch+=1;_query_epochs[peer_id]=_next_query_epoch
				var epoch:=int(_query_epochs.get(peer_id,0))
				var scope:=str(get_instance_id())+":"+str(peer_id)+":"+str(epoch)+":"
				var valid_session:=_query_session_valid.bind(peer_id,owner,account,player.get_instance_id(),_world.characters[peer_id].get_instance_id(),epoch,economy.get_instance_id())
				economy.auction_queries.submit(account,scope+request_id,payload,_query_reply.bind(peer_id,request_id),valid_session)
				return
		else: result=economy.market_query(_owner(peer_id),action,payload)
	_query_reply(result,peer_id,request_id)
@rpc("authority","call_remote","reliable",1)
func receive_query(request_id: String,result: Dictionary) -> void:
	query_finished.emit(request_id,result)

signal exchange_state_changed(snapshot: Dictionary)
func _publish_exchange(peer_id: int) -> void:
	var started := Time.get_ticks_usec() if observe.is_valid() else 0
	var snapshot: Dictionary=services.economy().market_query(_owner(peer_id),"exchange",{})
	if observe.is_valid(): observe.call({"kind":"exchange_snapshot","cost_us":Time.get_ticks_usec()-started})
	started = Time.get_ticks_usec() if observe.is_valid() else 0
	if snapshot.ok: receive_exchange_state.rpc_id(peer_id,snapshot)
	if observe.is_valid(): observe.call({"kind":"exchange_rpc_enqueue","cost_us":Time.get_ticks_usec()-started})
@rpc("authority","call_remote","reliable",1)
func receive_exchange_state(snapshot: Dictionary) -> void: exchange_state_changed.emit(snapshot)
