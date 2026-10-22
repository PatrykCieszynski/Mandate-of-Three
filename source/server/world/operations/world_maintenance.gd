extends RefCounted
## Concrete World lifecycle use case. The endpoint owns correlation/publication;
## existing economy owners retain all transaction/recovery decisions.
var world: WorldServer
var _profiles: Array[PlayerResource]=[]
func _init(owner: WorldServer) -> void:
	world=owner
	for peer: int in world.connected_players:
		var player: PlayerResource=world.connected_players[peer]
		if player.current_peer_id==peer and world.player_id_to_peer_id.get(player.player_id,0)==peer: _profiles.append(player)
func run() -> Dictionary:
	var result: Dictionary={"ok":false,"profiles_closed":false,"workers_stopped":false}
	if not await world.shutdown_economy(): return result
	# Keep SQLite open until native disconnect callbacks finish their saves.
	var deadline: int=Time.get_ticks_msec()+5000
	while not world.connected_players.is_empty() and Time.get_ticks_msec()<deadline: await world.get_tree().process_frame
	if not world.connected_players.is_empty(): return result
	if world.database.save_all_connected(world.connected_players)<0: return result
	# Disconnect's legacy save is best-effort. Explicitly verify captured latest
	# profiles before certifying closure; retain their resources on any failure.
	for player: PlayerResource in _profiles:
		if not world.database.store.save_player(player): return result
	if not await world.database.shutdown_database(): return result
	_profiles.clear()
	return {"ok":true,"profiles_closed":true,"workers_stopped":world.economy_bootstrap.status().stopped}
