extends Node
signal message_received(message: Dictionary)
signal operation_finished(id: String, result: Dictionary)
signal initialized(info: Dictionary)
const Chat = preload("res://source/common/gameplay/chat/world_chat.gd")
var info: Dictionary={}
var _known: Dictionary={}
func _ready() -> void:
	if GameMode.is_world_server(): WorldServer.curr.world_chat.message_ready.connect(_deliver)
func _deliver(peer: int, message: Dictionary) -> void:
	var c: Dictionary=WorldServer.curr.world_chat.context(peer)
	if not c.is_empty() and c.world==get_parent(): receive_message.rpc_id(peer,message)
func _process(_delta: float) -> void:
	if not GameMode.is_world_server(): return
	var service = WorldServer.curr.world_chat
	for peer: int in _known.keys():
		if service.context(peer).is_empty(): _known.erase(peer)
	for peer: int in get_parent().characters:
		var c: Dictionary=service.context(peer)
		if c.is_empty() or c.world!=get_parent() or _known.get(peer,0)==c.player.player_id: continue
		_known[peer]=c.player.player_id
		receive_info.rpc_id(peer,{"self":c.player.player_id,"name":c.player.display_name,"guild_available":false})
@rpc("authority","call_remote","reliable",0)
func receive_info(value: Dictionary) -> void:
	if GameMode.is_client(): info=value;initialized.emit(value)
@rpc("any_peer","call_remote","reliable",0)
func request(id: String, payload: Dictionary) -> void:
	if not GameMode.is_world_server(): return
	var peer: int=multiplayer.get_remote_sender_id()
	var service = WorldServer.curr.world_chat
	var c: Dictionary=service.context(peer)
	if c.is_empty() or c.world!=get_parent() or id.is_empty() or id.length()>80: return
	# Process-owned deduplication also survives a local MapInstance handoff.
	receive_result.rpc_id(peer,id,service.execute(peer,id,payload))
@rpc("authority","call_remote","reliable",0)
func receive_message(message: Dictionary) -> void:
	if GameMode.is_client(): message_received.emit(message)
@rpc("authority","call_remote","reliable",0)
func receive_result(id: String, result: Dictionary) -> void:
	if GameMode.is_client(): operation_finished.emit(id,result)
