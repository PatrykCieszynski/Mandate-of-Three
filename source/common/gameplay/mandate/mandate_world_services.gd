class_name MandateWorldServices
extends RefCounted
## Resolve current world session/store references on demand:
## reconnects and disposable test stores must not leave stale captured objects.

func _server() -> WorldServer:
	return WorldServer.curr

func available() -> bool:
	return _server() != null

func economy() -> WorldDatabase:
	return null if _server() == null or _server().inventory_runtime != null or _server().wallet_runtime != null else _server().database

func progression() -> WorldDatabase:
	return null if _server() == null else _server().database

func world_time() -> WorldTime:
	return null if _server() == null else _server().world_time

func item_store() -> ItemStoreSqlite:
	var server := _server()
	return null if server == null or server.inventory_runtime != null or server.wallet_runtime != null or server.database == null else server.database.item_store

func inventory_runtime() -> RefCounted:
	return null if _server()==null else _server().inventory_runtime

func wallet_runtime() -> RefCounted:
	return null if _server()==null else _server().wallet_runtime

func npc_runtime() -> RefCounted:
	return null if _server()==null else _server().npc_runtime

func storage_runtime() -> RefCounted:
	return null if _server()==null else _server().storage_runtime

func ground_item_runtime() -> RefCounted:
	return null if _server()==null else _server().ground_item_runtime

func seller_runtime() -> RefCounted:
	return null if _server()==null else _server().seller_runtime

func npc_interactions_allowed(peer: int) -> bool:
	if transfer_pending(peer): return false
	return mutations_allowed(peer) if npc_runtime()==null else inventory_runtime()!=null and inventory_runtime().mutations_allowed(peer)

func currency_allowed(peer_id: int) -> bool:
	if transfer_pending(peer_id): return false
	return mutations_allowed(peer_id) if wallet_runtime()==null else wallet_runtime().ready(peer_id)

func item_domain_ready() -> bool:
	return item_store() != null or ground_item_runtime()!=null

func player_for_peer(peer_id: int) -> PlayerResource:
	return null if _server() == null else _server().connected_players.get(peer_id)

func owner_id_for_peer(peer_id: int) -> int:
	var player := player_for_peer(peer_id)
	return 0 if player == null else player.player_id

func can_join_map_instance(peer_id: int, instance: ServerInstance) -> bool:
	return _server()!=null and _server().can_join_map_instance(peer_id,instance)

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

func mutations_allowed(peer_id: int) -> bool:
	# Other economics are not ported to the asynchronous runtime yet. Never let
	# an opt-in Inventory fixture fall back to synchronous SQLite mutations.
	return inventory_runtime()==null and wallet_runtime()==null and not transfer_pending(peer_id)

func transfer_pending(peer_id: int) -> bool:
	var server := _server()
	return server!=null and server.instance_manager!=null and server.instance_manager.transfers.gated(peer_id)

func interrupt_transfer(peer_id: int, reason: String) -> void:
	var server := _server()
	if server!=null and server.instance_manager!=null:
		server.instance_manager.transfers.interrupt(peer_id,reason)

func hydrate_transfer(peer_id: int, host: ServerInstance) -> Dictionary:
	var server := _server()
	return {} if server==null or server.instance_manager==null else server.instance_manager.transfers.hydrate(peer_id,host)
