extends DataRequestHandler
func data_request_handler(peer_id: int, _instance: ServerInstance, args: Dictionary) -> Dictionary:
	var server: WorldServer=ServerInstance.world_server
	return {"ok":true,"stats":server.character_stats.snapshot(server,peer_id)}
