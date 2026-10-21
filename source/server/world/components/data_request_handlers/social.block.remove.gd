extends DataRequestHandler
## Removes [param id] from the caller's block list. No-op if not blocked.


func data_request_handler(
	peer_id: int,
	instance: ServerInstance,
	args: Dictionary
) -> Dictionary:
	var world_server: WorldServer = instance.world_server

	var from_player: PlayerResource = world_server.connected_players.get(peer_id)
	if from_player == null:
		return {"error": 1, "ok": false, "msg": "Not connected."}

	var target_id: int = int(args.get("id", 0))
	if target_id <= 0:
		return {"error": 2, "ok": false, "msg": "Invalid target."}

	if not BlockList.is_blocked(from_player.player_id, target_id):
		return {"error": 0, "ok": true, "msg": "Not blocked.", "id": target_id}

	var mutation:=RealmProfileMutation.new(world_server.database.store,[from_player])
	if not mutation.started: return mutation.failure()

	var ids: PackedInt64Array = from_player.blocked_ids.duplicate()
	var idx: int = ids.find(target_id)
	if idx >= 0:
		ids.remove_at(idx)
		from_player.blocked_ids = ids

	if not mutation.save_player(from_player): return mutation.abort()
	if not mutation.commit(): return mutation.failure()
	BlockList.remove(from_player.player_id, target_id)

	return {"error": 0, "ok": true, "msg": "Unblocked.", "id": target_id}
