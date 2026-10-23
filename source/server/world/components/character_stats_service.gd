extends RefCounted
## Local World owner; generic RPC admission supplies the authenticated character.
const Limits = preload("res://source/server/runtime/runtime_capacity_settings.gd")
const RECEIPT_CACHE_SIZE: int=32
const ATTEMPT_WINDOW_MS: int=1000
var _attempts: Dictionary={}
var _receipts: Dictionary={}
func execute(server: WorldServer, peer: int, args: Dictionary) -> Dictionary:
	if not server.inventory_master_available() or server.request_instance(peer)==null: return {"ok":false,"error":"session"}
	if args.size()!=2 or not args.get("command_id") is String or not args.get("attribute") is String:
		return {"ok":false,"error":"payload"}
	var id: String=args.command_id
	var attribute := StringName(args.attribute)
	if id.is_empty() or id.length()>80 or not AttributeMap.KEYS.has(attribute): return {"ok":false,"error":"payload"}
	var player: PlayerResource=server.connected_players[peer]
	if server.database==null or server.database.store==null: return {"ok":false,"error":"storage"}
	if server.database.store is WorldStorePostgres and server.database.store.last_write_error=="outcome_unknown":
		return {"ok":false,"error":"outcome_unknown"}
	for owner: int in _receipts.keys():
		if not server.player_id_to_peer_id.has(owner): _receipts.erase(owner)
	var receipts: Dictionary=_receipts.get(player.player_id,{})
	if receipts.has(id):
		return {"ok":true,"replay":true,"stats":snapshot(server,peer)} if receipts[id]==str(attribute) else {"ok":false,"error":"command_conflict"}
	var now := Time.get_ticks_msec()
	for old: int in _attempts.keys():
		if not server.connected_players.has(old): _attempts.erase(old)
	var recent: Array=_attempts.get(peer,[]).filter(func(t: int)->bool:return now-t<ATTEMPT_WINDOW_MS)
	var limit: int=Limits.DEFAULTS.stats_attempts_per_second if server.runtime_settings==null else server.runtime_settings.value("stats_attempts_per_second")
	if recent.size()>=limit: return {"ok":false,"error":"rate_limited"}
	recent.append(now);_attempts[peer]=recent
	if server.database.pending_progression_player(player.player_id,player)!=player: return {"ok":false,"error":"stale"}
	var result: Dictionary=server.database.store.spend_attribute(player,id,attribute)
	if not result.get("ok",false): return result
	receipts[id]=str(attribute)
	if receipts.size()>RECEIPT_CACHE_SIZE: receipts.erase(receipts.keys()[0])
	_receipts[player.player_id]=receipts
	if not result.get("replay",false):
		player.attributes.assign(result.attributes)
		player.available_attributes_points=int(result.points)
		player.stats_revision=int(result.revision)
		server.database.dirty_progression.erase(player.player_id)
		server.refresh_character_stats(peer)
	return {"ok":true,"replay":bool(result.get("replay",false)),"stats":snapshot(server,peer)}
func snapshot(server: WorldServer, peer: int) -> Dictionary:
	var player: PlayerResource=server.connected_players.get(peer)
	if player==null: return {}
	var attributes: Dictionary={}
	for key: StringName in AttributeMap.KEYS: attributes[str(key)]=int(player.attributes.get(key,0))
	return {"version":1,"revision":player.stats_revision,"attributes":attributes,"available_points":player.available_attributes_points,"available_skill_points":player.available_skill_points,"level":player.level,"experience":player.experience,"xp_to_next":player.level_xp_to_next(),"thresholds_claimed":player.exp_thresholds_claimed,"combat":server.runtime_combat_stats(player.player_id)}
