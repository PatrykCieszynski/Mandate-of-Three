extends DataRequestHandler


func data_request_handler(
	peer_id: int,
	instance: ServerInstance,
	args: Dictionary
) -> Dictionary:
	var world_server: WorldServer = instance.world_server
	var store: RefCounted = world_server.database.store

	var from_player: PlayerResource = world_server.connected_players.get(peer_id)
	if from_player == null:
		return {"error": 1, "ok": false, "name": "Unknown"}

	var target_id: int = int(args.get("id", 0))
	if target_id <= 0:
		return {"error": 1, "ok": false, "name": "Unknown"}

	if target_id == from_player.player_id:
		return {"error": 1, "ok": false, "msg": "Can't add yourself."}

	var target_row: Dictionary = store.get_player_profile_row(target_id)
	if target_row.is_empty():
		return {"error": 1, "ok": false, "name": "Unknown"}

	if from_player.friends.has(target_id):
		return {"error": 1, "ok": false, "msg": "Already friend."}

	var mutation:=RealmProfileMutation.new(world_server.database.store,[from_player])
	if not mutation.started: return mutation.failure()
	from_player.friends.append(target_id)
	if not mutation.save_player(from_player): return mutation.abort()
	if not mutation.commit(): return mutation.failure()

	var target_peer_id: int = int(world_server.player_id_to_peer_id.get(target_id, 0))
	if target_peer_id > 0:
		world_server.data_push.rpc_id(
			target_peer_id,
			&"notification",
			{
				"topic": "friend.request",
				"player_name": from_player.display_name,
				"player_id": from_player.player_id
			}
		)

	return {"error": 0, "ok": true, "msg": "Added friend."}
