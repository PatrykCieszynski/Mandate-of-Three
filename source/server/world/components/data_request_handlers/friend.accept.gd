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

	var target_id: int = int(args.get("player_id", 0))
	if target_id <= 0:
		return {"error": 1, "ok": false, "msg": "Invalid player."}

	if target_id == from_player.player_id:
		return {"error": 1, "ok": false, "msg": "Can't add yourself."}

	var row: Dictionary = store.get_player_profile_row(target_id)
	if row.is_empty():
		return {"error": 1, "ok": false, "name": "Unknown"}

	if from_player.friends.has(target_id):
		return {"error": 1, "ok": false, "msg": "Already friend."}

	var mutation:=RealmProfileMutation.new(world_server.database.store,[from_player])
	if not mutation.started: return mutation.failure()
	from_player.friends.append(target_id)

	# Persist now (safe + predictable)
	if not mutation.save_player(from_player): return mutation.abort()
	if not mutation.commit(): return mutation.failure()

	return {"error": 0, "ok": true, "msg": "Added friend."}
