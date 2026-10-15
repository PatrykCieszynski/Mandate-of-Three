class_name MandateWorldServices
extends RefCounted
## Narrow TinyMMO boundary. Resolve current session/store references on demand:
## reconnects and disposable test stores must not leave stale captured objects.

func _server() -> WorldServer:
	return WorldServer.curr

func available() -> bool:
	return _server() != null

func economy() -> WorldDatabase:
	return null if _server() == null else _server().database

func progression() -> WorldDatabase:
	return economy()

func world_time() -> WorldTime:
	return null if _server() == null else _server().world_time

func item_store() -> ItemStoreSqlite:
	var server := _server()
	return null if server == null or server.database == null else server.database.item_store

func item_domain_ready() -> bool:
	return item_store() != null

func player_for_peer(peer_id: int) -> PlayerResource:
	return null if _server() == null else _server().connected_players.get(peer_id)

func owner_id_for_peer(peer_id: int) -> int:
	var player := player_for_peer(peer_id)
	return 0 if player == null else player.player_id

func peers() -> Array:
	return [] if _server() == null else _server().connected_players.keys()

func players() -> Array:
	return [] if _server() == null else _server().connected_players.values()

func current_player(owner_id: int, fallback: PlayerResource = null) -> PlayerResource:
	var player: PlayerResource = fallback
	if progression() != null:
		player = progression().pending_progression_player(owner_id,player)
	for current: PlayerResource in players():
		if current.player_id == owner_id: return current
	return player

func update_runtime_equipment(owner_id: int, snapshot: Dictionary) -> bool:
	return _server() != null and _server().update_runtime_equipment(owner_id,snapshot)

func runtime_stats(owner_id: int) -> Dictionary:
	if _server() == null: return {}
	return _server().runtime_equipment.get(owner_id,{}).get("stats",{}).duplicate(true)

func runtime_attack(owner_id: int) -> int:
	return -1 if _server() == null else _server().runtime_attack(owner_id)

func runtime_attack_speed_ratio(owner_id: int) -> float:
	return -1.0 if _server() == null else _server().runtime_attack_speed_ratio(owner_id)
