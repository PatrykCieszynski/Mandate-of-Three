extends DataRequestHandler


func data_request_handler(peer_id: int, instance: ServerInstance, args: Dictionary) -> Dictionary:
	var world_server: WorldServer = instance.world_server
	var store: RefCounted = world_server.database.store

	var guild_name: String = str(args.get("guild_name", "")).strip_edges()
	if guild_name.is_empty():
		return {"error": 1, "ok": false, "message": "Guild doesn't exist."}

	var player: PlayerResource = world_server.connected_players.get(peer_id)
	if player == null:
		return {"error": 1, "ok": false, "message": ""}

	var guild_id: int = store.get_guild_id_by_name(guild_name)
	if guild_id <= 0:
		return {"error": 1, "ok": false, "message": ""}

	var guild: Guild = store.get_guild(guild_id)
	if guild == null:
		return {"error": 1, "ok": false, "message": ""}

	if not guild.members.has(player.player_id):
		return {"error": 1, "ok": false, "message": ""}

	if guild.leader_id == player.player_id:
		return {"error": 1, "ok": false, "message": ""}

	var mutation:=RealmProfileMutation.new(store,[player])
	if not mutation.started: return mutation.failure()

	# Update player fields
	if player.active_guild_id == guild_id:
		player.active_guild_id = 0

	var idx: int = player.joined_guild_ids.find(guild_id)
	if idx != -1:
		player.joined_guild_ids.remove_at(idx)

	# Update guild
	guild.remove_member(player.player_id)

	if not mutation.save_player(player): return mutation.abort()
	if not mutation.save_guild(guild): return mutation.abort()

	if not mutation.commit(): return mutation.failure()

	store.add_guild_log(guild_id, "left", player.display_name)

	# Sync the client's cached active_guild_id (it may have been cleared above).
	world_server.data_push.rpc_id(peer_id, &"active_guild_id.set", {"active_guild_id": player.active_guild_id})

	return {"error": 0, "ok": true, "message": "Guild left."}
