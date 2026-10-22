extends DataRequestHandler


func data_request_handler(
	peer_id: int,
	instance: ServerInstance,
	args: Dictionary
) -> Dictionary:
	var legacy_players: Dictionary = instance.players_by_peer_id
	var legacy_map: Map = instance.instance_map
	if legacy_map == null:
		return {"ok": false, "error": ERR_UNAVAILABLE}
	var player: Player = legacy_players.get(peer_id, null)
	if not player:
		return {"ok": false}

	var table: TradeTable = legacy_map.get_trade_table(int(args.get("table", 0)))
	if table == null:
		return {"ok": false}

	if table.server_remove_player(player):
		TradeService.broadcast(instance, table)
	return {"ok": true}
