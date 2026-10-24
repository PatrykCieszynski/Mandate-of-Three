class_name ChatService
extends Node
## Compatibility adapter for ephemeral moderation notices; Chat V1 owns player chat.
var _system_msg_seq: int = 0

func recent(_limit: int = 30) -> Array:
	return [] # Player chat is not collected by the retired dashboard history.

func push_system_to_player(instance: ServerInstance, player_id: int, text: String) -> void:
	# instance is just a handle to the WorldServer for peer-id lookup; some callers
	# to WorldServer.curr when null.
	var ws: WorldServer = instance.world_server if instance != null else WorldServer.curr
	if ws == null:
		return
	var peer_id: int = int(ws.player_id_to_peer_id.get(player_id, 0))
	if peer_id <= 0:
		return # offline — system notices aren't stored, so there's nothing to deliver

	_system_msg_seq += 1
	var pushed: Dictionary = {
		"conversation_id": ChatConstants.system_conversation_id(player_id),
		"channel": ChatConstants.CHANNEL_SYSTEM,
		"text": text,
		"name": ChatConstants.SYSTEM_SENDER_NAME,
		"id": ChatConstants.SYSTEM_SENDER_ID,
		"msg_id": _system_msg_seq,
		"time_ms": int(Time.get_unix_time_from_system() * 1000.0),
	}
	WorldServer.curr.data_push.rpc_id(peer_id, &"chat.message", pushed)
