extends Node
## Map-local RPC admission/publication; membership lives on the World process.
signal state_changed(snapshot: Dictionary)
signal operation_finished(id: String, result: Dictionary)
const Service = preload("res://source/common/gameplay/party/party_service.gd")
var state: Dictionary = {}
var _elapsed: float = 0
var _sent: Dictionary = {}
var _history: Dictionary = {}
var _last: Dictionary = {}
var _world: Node3D
func _ready() -> void: _world=get_parent()
func admitted(peer: int) -> bool:
	var server = WorldServer.curr
	if not GameMode.is_world_server() or server==null or not _world.services.available() or _world.services.transfer_pending(peer): return false
	var player = server.connected_players.get(peer)
	var host = _world.get_parent() as ServerInstance
	return player!=null and player.current_peer_id==peer and server.player_id_to_peer_id.get(player.player_id,0)==peer and _world.characters.has(peer) and host!=null and peer in host.connected_peers
func perform(peer: int, payload: Dictionary) -> Dictionary:
	if not admitted(peer): return {"ok":false,"error":"session"}
	return WorldServer.curr.party_service.command(_world.services.owner_id_for_peer(peer),payload)
@rpc("any_peer","call_remote","reliable",0)
func request(id: String, payload: Dictionary) -> void:
	if not GameMode.is_world_server(): return
	var peer: int=multiplayer.get_remote_sender_id()
	if not admitted(peer) or id.is_empty() or id.length()>80: return
	if not Service.valid(payload):
		receive_result.rpc_id(peer,id,{"ok":false,"error":"payload"})
		return
	var history: Dictionary=_history.get(peer,{})
	var result: Dictionary
	if history.has(id):
		result=history[id].result if history[id].payload==payload else {"ok":false,"error":"command_conflict"}
	else:
		var now: int=Time.get_ticks_msec()
		if now-int(_last.get(peer,-1000))<200: result={"ok":false,"error":"rate_limited"}
		else: _last[peer]=now;result=perform(peer,payload)
		if history.size()>=64: history.erase(history.keys()[0])
		history[id]={"payload":payload.duplicate(true),"result":result};_history[peer]=history
	receive_result.rpc_id(peer,id,result)
	publish()
func publish() -> void:
	var service = _world.services.party()
	if service==null: return
	for peer: int in _sent.keys():
		if not _world.characters.has(peer): _sent.erase(peer);_history.erase(peer);_last.erase(peer)
	for peer: int in _world.characters:
		if not admitted(peer): continue
		var snapshot: Dictionary=service.snapshot(_world.services.owner_id_for_peer(peer),_world)
		if snapshot!=_sent.get(peer,{}):
			if rpc_id(peer,&"receive_state",snapshot)==OK: _sent[peer]=snapshot
func _process(delta: float) -> void:
	if not GameMode.is_world_server(): return
	_elapsed+=delta
	if _elapsed>=0.25: _elapsed=0;publish()
@rpc("authority","call_remote","reliable",0)
func receive_state(snapshot: Dictionary) -> void:
	if not GameMode.is_client(): return
	state=snapshot.duplicate(true);state_changed.emit(state)
@rpc("authority","call_remote","reliable",0)
func receive_result(id: String, result: Dictionary) -> void:
	if GameMode.is_client(): operation_finished.emit(id,result)
