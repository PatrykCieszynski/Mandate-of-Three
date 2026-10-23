extends DataRequestHandler
func data_request_handler(peer_id: int, _instance: ServerInstance, args: Dictionary) -> Dictionary:
	var server: WorldServer=ServerInstance.world_server
	return server.character_stats.execute(server,peer_id,args)
