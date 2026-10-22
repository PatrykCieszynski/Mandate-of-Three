extends RefCounted
signal message_ready(peer: int, message: Dictionary)
## Ephemeral single-World routing. No store, offline queue or client identities.
const CHANNELS = ["general","trade","local","party","guild","whisper"]
var _server: Node
var _limits: RefCounted
var _rates: Dictionary = {}
var _recent: Dictionary = {}
var _serial: int = 0
func _init(server: Node, limits: RefCounted = null) -> void:
	_server=server;_limits=limits
func limit(key: String) -> int:
	var settings = _limits if _limits!=null else _server.runtime_settings
	return settings.value(key) if settings!=null else int(preload("res://source/server/runtime/runtime_capacity_settings.gd").DEFAULTS[key])
func context(peer: int) -> Dictionary:
	var p = _server.connected_players.get(peer)
	if p==null or p.current_peer_id!=peer or _server.player_id_to_peer_id.get(p.player_id,0)!=peer: return {}
	if _server.instance_manager!=null and _server.instance_manager.transfers.gated(peer): return {}
	var host = _server.request_instance(peer)
	if host==null or peer not in host.connected_peers: return {}
	var world = host.get_node_or_null("GameWorld")
	if world==null or not world.characters.has(peer): return {}
	return {"player":p,"world":world,"peer":peer}
static func valid(payload: Dictionary) -> bool:
	if var_to_bytes(payload).size()>4096: return false
	if payload.get("action")=="lookup": return payload.size()==2 and payload.get("name") is String and payload.name.length()<=64
	if payload.get("action")!="send" or payload.get("channel") not in CHANNELS or not payload.get("text") is String or payload.text.to_utf8_buffer().size()>2048: return false
	if payload.channel=="whisper":
		var target = payload.get("target")
		return payload.size()==4 and (target is int or target is float) and is_finite(float(target)) and float(target)==floor(float(target)) and target>0 and target<=9007199254740991
	return payload.size()==3
static func normalize(text: String) -> String:
	for i: int in text.length():
		var c: int=text.unicode_at(i)
		if c<32 or (c>=127 and c<=159) or c in [0x2028,0x2029,0x202a,0x202b,0x202c,0x202d,0x202e,0x2066,0x2067,0x2068,0x2069]: return ""
	var value: String=text.strip_edges()
	return value if value.length()<=256 else ""
func attempt(peer: int, now: int) -> bool:
	var c: Dictionary=context(peer)
	if c.is_empty(): return false
	var owner: int=c.player.player_id
	var rate: Dictionary=_rates.get(owner,{"attempts":[],"light":[],"last":{}})
	for bucket: String in ["attempts","light"]:
		var window: int=limit("chat_flood_window_ms") if bucket=="attempts" else limit("chat_light_window_ms")
		rate[bucket]=rate[bucket].filter(func(t: int)->bool: return now-t<window)
	_rates[owner]=rate
	if rate.attempts.size()>=limit("chat_flood_count"): return false
	rate.attempts.append(now)
	return true
func prune() -> void:
	for owner: int in _rates.keys():
		if not _server.player_id_to_peer_id.has(owner): _rates.erase(owner);_recent.erase(owner)
func execute(peer: int, id: String, payload: Dictionary, now: int = Time.get_ticks_msec()) -> Dictionary:
	var current: Dictionary=context(peer)
	if current.is_empty(): return {"ok":false,"error":"session"}
	var owner: int=current.player.player_id
	var history: Dictionary=_recent.get(owner,{})
	if history.has(id): return history[id].result if history[id].payload==payload else {"ok":false,"error":"command_conflict"}
	if not attempt(peer,now): return {"ok":false,"error":"rate_limited"}
	if not valid(payload): return {"ok":false,"error":"payload"}
	var result: Dictionary=handle(peer,payload,now)
	if history.size()>=32: history.erase(history.keys()[0])
	history[id]={"payload":payload.duplicate(true),"result":result};_recent[owner]=history
	return result
func handle(peer: int, payload: Dictionary, now: int = Time.get_ticks_msec()) -> Dictionary:
	var c: Dictionary=context(peer)
	if c.is_empty(): return {"ok":false,"error":"session"}
	if not valid(payload): return {"ok":false,"error":"payload"}
	var player = c.player
	if payload.action=="lookup":
		var found: Dictionary={}
		for other_peer: int in _server.connected_players:
			var other: Dictionary=context(other_peer)
			if not other.is_empty() and other.player.player_id!=player.player_id and other.player.display_name.nocasecmp_to(payload.name.strip_edges())==0:
				if not found.is_empty(): return {"ok":false,"error":"ambiguous_player"}
				found={"ok":true,"target":other.player.player_id,"name":other.player.display_name}
		return found if not found.is_empty() else {"ok":false,"error":"recipient_offline"}
	var text: String=normalize(payload.text)
	if text.is_empty(): return {"ok":false,"error":"invalid_text"}
	var channel: String=payload.channel
	if channel=="guild": return {"ok":false,"error":"guild_unavailable"}
	var pid: int=_server.party_service.membership.get(player.player_id,0)
	if channel=="party" and pid==0: return {"ok":false,"error":"not_in_party"}
	var target: int=int(payload.get("target",0))
	if channel=="whisper" and (target==player.player_id or context(int(_server.player_id_to_peer_id.get(target,0))).is_empty()): return {"ok":false,"error":"recipient_offline"}
	if channel=="whisper" and BlockList.is_blocked(player.player_id,target): return {"ok":false,"error":"recipient_blocked"}
	var rate: Dictionary=_rates.get(player.player_id,{"attempts":[],"light":[],"last":{}})
	_rates[player.player_id]=rate
	if channel in ["general","trade"]:
		var delay: int=limit("chat_general_ms") if channel=="general" else limit("chat_trade_ms")
		if now-int(rate.last.get(channel,-delay))<delay: return {"ok":false,"error":"rate_limited"}
		rate.last[channel]=now
	else:
		rate.light=rate.light.filter(func(t: int)->bool: return now-t<limit("chat_light_window_ms"))
		if rate.light.size()>=limit("chat_light_count"): return {"ok":false,"error":"rate_limited"}
		rate.light.append(now)
	_serial+=1
	var message: Dictionary={"id":_serial,"channel":channel,"sender":player.player_id,"name":player.display_name,"target":target,"text":text}
	if channel=="whisper": message.target_name=_server.connected_players[int(_server.player_id_to_peer_id[target])].display_name
	for recipient: int in _server.connected_players.keys():
		var other: Dictionary=context(recipient)
		if other.is_empty(): continue
		var owner: int=other.player.player_id
		if owner!=player.player_id and BlockList.is_blocked(owner,player.player_id): continue
		if channel=="whisper" and owner not in [player.player_id,target]: continue
		if channel=="party" and _server.party_service.membership.get(owner,0)!=pid: continue
		if channel=="local" and (other.world!=c.world or other.world.characters[recipient].position.distance_to(c.world.characters[peer].position)>limit("chat_local_radius")): continue
		message_ready.emit(recipient,message)
	return {"ok":true}
func system(text: String, recipients: Array[int]) -> void:
	text=normalize(text)
	if text.is_empty(): return
	_serial+=1
	var message: Dictionary={"id":_serial,"channel":"system","sender":0,"name":"System","target":0,"text":text}
	var sent: Dictionary={}
	for peer: int in recipients:
		var c: Dictionary=context(peer)
		if not c.is_empty() and not sent.has(peer):
			sent[peer]=true;message_ready.emit(peer,message)
