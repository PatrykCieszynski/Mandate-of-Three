extends RefCounted
## World-owned two-party negotiation and committed-state reconciliation. No SQL here.
const Contract = preload("res://source/common/gameplay/trade/player_trade_contract.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
signal changed
var world: WorldServer
var executor: RefCounted
var trades: Dictionary={}
var _members: Dictionary={}
var _terminal: Dictionary={}
var _jobs: Dictionary={}
var _draining:=false
func _init(server: WorldServer, pool: RefCounted) -> void: world=server;executor=pool
func _limit(key: String) -> int:
	return world.runtime_settings.value(key) if world.runtime_settings!=null else int(preload("res://source/server/runtime/runtime_capacity_settings.gd").DEFAULTS[key])
func _context(peer: int) -> Dictionary:
	if not world.inventory_master_available(): return {}
	var player: PlayerResource=world.connected_players.get(peer)
	if player==null or player.current_peer_id!=peer or world.player_id_to_peer_id.get(player.player_id,0)!=peer: return {}
	if world.instance_manager==null or world.instance_manager.transfers.gated(peer): return {}
	var host: ServerInstance=world.instance_manager.find_instance_for_peer(peer)
	var map: Node=host.get_node_or_null("GameWorld") if host!=null else null
	if map==null or not map.characters.has(peer) or not map.characters[peer].alive: return {}
	var context: Dictionary=world.wallet_runtime.context_for_peer(peer)
	return {} if context.is_empty() else {"player":player,"peer":peer,"map":map,"body":map.characters[peer],"context":context}
func busy(peer: int) -> bool:
	var player: PlayerResource=world.connected_players.get(peer)
	return player!=null and _members.has(player.player_id)
func _near(a: Dictionary, b: Dictionary) -> bool:
	return not a.is_empty() and not b.is_empty() and a.map==b.map and a.body.position.distance_to(b.body.position)<=float(_limit("trade_range_cm"))/100.0
func command(peer: int, payload: Dictionary) -> Dictionary:
	if not Contract.valid(payload): return {"ok":false,"error":"payload"}
	var c:=_context(peer)
	if c.is_empty(): return {"ok":false,"error":"session"}
	if payload.action=="recover": return _recover(c,payload.trade_id)
	if _draining: return {"ok":false,"error":"unavailable"}
	var owner: int=c.player.player_id
	if payload.action=="invite":
		var other:=_context(world.player_id_to_peer_id.get(payload.target,0))
		if not _near(c,other) or owner==payload.target or c.context.account_id==other.context.account_id: return {"ok":false,"error":"target"}
		if _members.has(owner) or _members.has(payload.target): return {"ok":false,"error":"busy"}
		if not _ready(c.peer) or not _ready(other.peer): return {"ok":false,"error":"recovery_required"}
		var id: String="trade-"+Crypto.new().generate_random_bytes(16).hex_encode()
		trades[id]={"id":id,"phase":"invited","version":1,"owners":[owner,payload.target],"contexts":[c.context,other.context],"offers":[{"items":[],"yang":0},{"items":[],"yang":0}],"accepted":[false,false],"deadline":Time.get_ticks_msec()+_limit("trade_invite_timeout_ms"),"ticket":0,"tries":0,"retry_at":0,"error":""}
		_members[owner]=id;_members[payload.target]=id;_terminal.erase(owner);_terminal.erase(payload.target)
		return {"ok":true,"trade_id":id}
	var trade: Dictionary=trades.get(payload.trade_id,{})
	if trade.is_empty() or _members.get(owner,"")!=payload.trade_id or owner not in trade.owners: return {"ok":false,"error":"trade"}
	var side: int=trade.owners.find(owner)
	if trade.phase not in ["invited","offer"]: return {"ok":false,"error":"settling"}
	if payload.action=="cancel": _close(trade,"cancelled");return {"ok":true}
	var other:=_context(world.player_id_to_peer_id.get(trade.owners[1-side],0))
	if not _near(c,other) or not Sessions.same_context(c.context,trade.contexts[side]) or not Sessions.same_context(other.context,trade.contexts[1-side]): _close(trade,"cancelled");return {"ok":false,"error":"session"}
	if payload.action=="join":
		if side!=1 or trade.phase!="invited": return {"ok":false,"error":"phase"}
		trade.phase="offer";trade.deadline=Time.get_ticks_msec()+_limit("trade_idle_timeout_ms")
		return {"ok":true}
	_refresh_offers(trade)
	if trade.phase!="offer" or payload.version!=trade.version: return {"ok":false,"error":"offer_changed"}
	if payload.action=="offer":
		var lines: Array=[]
		var owned: Array=world.inventory_runtime.snapshot_for_peer(peer).get("items",[])
		for line: Dictionary in payload.items:
			var found: Array=owned.filter(func(item: Dictionary)->bool:return item.uid==line.uid and str(item.revision)==line.revision and item.location=="bag")
			if found.size()!=1: return {"ok":false,"error":"item_changed"}
			var definition:=ItemDefinitions.get_definition(StringName(found[0].definition_id))
			if definition==null or not definition.tradeable: return {"ok":false,"error":"not_tradeable"}
			lines.append({"uid":line.uid,"revision":int(line.revision)})
		trade.offers[side]={"items":lines,"yang":int(payload.yang)}
		trade.error=""
		trade.version+=1;trade.accepted=[false,false]
		trade.deadline=Time.get_ticks_msec()+_limit("trade_idle_timeout_ms")
		return {"ok":true}
	if payload.action=="confirm":
		if not _ready(peer) or not _ready(other.peer): return {"ok":false,"error":"recovery_required"}
		trade.accepted[side]=true
		if trade.accepted.all(func(v: bool)->bool:return v): _submit(trade)
		return {"ok":true,"trade_id":trade.id}
	return {"ok":false,"error":"request"}
func _ready(peer: int) -> bool: return world.inventory_runtime.mutations_allowed(peer) and world.wallet_runtime.settled(peer)
func _refresh_offers(t: Dictionary) -> void:
	if t.phase!="offer": return
	var changed_offer:=false
	for side: int in 2:
		var peer: int=world.player_id_to_peer_id.get(t.owners[side],0)
		if peer<=0 or not world.inventory_runtime.mutations_allowed(peer): continue
		var owned: Array=world.inventory_runtime.snapshot_for_peer(peer).get("items",[])
		var retained: Array=[]
		for line: Dictionary in t.offers[side].items:
			if owned.any(func(item: Dictionary)->bool:return item.uid==line.uid and str(item.revision)==str(line.revision) and item.location=="bag"): retained.append(line)
		if retained.size()!=t.offers[side].items.size():
			t.offers[side].items=retained;changed_offer=true
	if changed_offer:
		t.version+=1;t.accepted=[false,false];t.error="item_changed"
func _submit(t: Dictionary) -> void:
	t.captures=[]
	for index: int in 2:
		var context: Dictionary=t.contexts[index]
		var peer: int=world.player_id_to_peer_id.get(context.character,0)
		var capture: Dictionary=world.wallet_runtime.reserve_exchange(context.account_id,t.id)
		if capture.is_empty(): _release(t,{"ok":false});_close(t,"participant_busy");return
		t.captures.append(capture)
		if not world.inventory_runtime.hold_external(peer,t.id): _release(t,{"ok":false});_close(t,"participant_busy");return
	var participants: Array=[]
	for index: int in 2:
		participants.append({"context":t.contexts[index],"items":t.offers[index].items,"yang":t.offers[index].yang,"income":t.captures[index].income,"token":t.captures[index].token})
	t.phase="settling"
	var queued: Dictionary=executor.submit_trade(t.contexts[0],t.id,participants)
	if not queued.queued: _release(t,{"ok":false});_close(t,str(queued.error));return
	t.ticket=queued.ticket;_jobs[queued.ticket]={"id":t.id,"kind":"execute"}
func _release(t: Dictionary, result: Dictionary) -> void:
	for index: int in t.get("captures",[]).size():
		var account: int=t.contexts[index].account_id
		world.wallet_runtime.finish_exchange(account,t.id,result)
		world.inventory_runtime.finish_external(account,t.id)
func _close(t: Dictionary, phase: String) -> void:
	for owner: int in t.owners:
		_members.erase(owner)
		_terminal[owner]={"id":t.id,"phase":phase,"version":t.version}
	trades.erase(t.id)
func _recover(c: Dictionary, id: String) -> Dictionary:
	var t: Dictionary=trades.get(id,{})
	if not t.is_empty():
		if c.player.player_id not in t.owners: return {"ok":false,"error":"trade"}
		if t.phase=="paused": t.tries=0;t.retry_at=0
		return {"ok":true,"pending":true}
	if _jobs.values().any(func(j: Dictionary)->bool:return j.get("peer",0)==c.peer): return {"ok":false,"error":"busy"}
	var queued: Dictionary=executor.submit_trade_receipt(c.context,id)
	if not queued.queued: return {"ok":false,"error":queued.error}
	_jobs[queued.ticket]={"id":id,"kind":"lookup","peer":c.peer,"context":c.context}
	return {"ok":true,"pending":true}
func snapshot(peer: int) -> Dictionary:
	var c:=_context(peer)
	if c.is_empty(): return {"id":"","phase":"unavailable","version":0,"self":0,"candidates":[]}
	var owner: int=c.player.player_id
	var t: Dictionary=trades.get(_members.get(owner,""),{})
	var value: Dictionary={"id":"","phase":"idle","version":0,"self":owner,"candidates":[]}
	if t.is_empty():
		value.merge(_terminal.get(owner,{}),true)
		for other_peer: int in world.connected_players:
			if value.candidates.size()>=64: break
			if other_peer==peer: continue
			var other:=_context(other_peer)
			if _near(c,other) and not busy(other_peer): value.candidates.append({"id":other.player.player_id,"name":other.player.display_name})
		return value
	var side: int=t.owners.find(owner)
	value.merge({"id":t.id,"phase":t.phase,"version":t.version,"incoming":side==1,"accepted":t.accepted.duplicate(),"own_side":side,"error":t.error,"offers":[]},true)
	for index: int in 2:
		var other_peer: int=world.player_id_to_peer_id.get(t.owners[index],0)
		var player: PlayerResource=world.connected_players.get(other_peer)
		var owned: Array=world.inventory_runtime.snapshot_for_peer(other_peer).get("items",[])
		var offered: Array=[]
		for line: Dictionary in t.offers[index].items:
			var found: Array=owned.filter(func(item: Dictionary)->bool:return item.uid==line.uid)
			if not found.is_empty():
				var item: Dictionary=found[0]
				var definition:=ItemDefinitions.get_definition(StringName(item.definition_id))
				var label: String=item.item_name
				if not definition.stats_per_upgrade.is_empty(): label+=" +%d"%int(item.upgrade_level)
				offered.append({"uid":line.uid,"revision":str(line.revision),"name":label,"amount":str(item.amount),"icon":str(definition.icon_id),"details":{"affixes":item.get("affixes",[]),"stats":item.get("stats",{}),"sockets":item.get("sockets",[])}})
		value.offers.append({"name":player.display_name if player!=null else "Offline","items":offered,"yang":str(t.offers[index].yang)})
	return value
func poll() -> void:
	for event: Dictionary in executor.poll():
		var job: Dictionary=_jobs.get(event.ticket,{})
		_jobs.erase(event.ticket)
		if job.is_empty(): continue
		if job.kind=="lookup":
			var c:=_context(job.peer)
			if not c.is_empty() and Sessions.same_context(c.context,job.context) and (event.result.get("ok",false) or event.result.get("resolved",false)):
				_terminal[c.player.player_id]={"id":job.id,"version":0,"phase":"complete" if event.result.get("ok",false) else "cancelled"}
			continue
		var t: Dictionary=trades.get(job.id,{})
		if t.is_empty(): continue
		t.ticket=0
		if event.result.get("ok",false) or event.result.get("resolved",false) or event.result.get("error","") not in ["storage","outcome_unknown","stale_session","session_required","recovery_required"]:
			t.result=event.result
			_release(t,event.result);t.phase="reconcile"
		else: t.phase="paused";t.error=str(event.result.get("error","storage"));t.retry_at=Time.get_ticks_msec()+1000
	for t: Dictionary in trades.values():
		if t.phase in ["invited","offer"]:
			var a:=_context(world.player_id_to_peer_id.get(t.owners[0],0));var b:=_context(world.player_id_to_peer_id.get(t.owners[1],0))
			if _draining or not _near(a,b) or not Sessions.same_context(a.context,t.contexts[0]) or not Sessions.same_context(b.context,t.contexts[1]) or Time.get_ticks_msec()>t.deadline: _close(t,"cancelled")
			else: _refresh_offers(t)
		elif t.phase=="paused" and t.ticket==0 and t.tries<3 and Time.get_ticks_msec()>=t.retry_at:
			var queued: Dictionary=executor.submit_trade_recover(t.contexts[0],t.id,[t.contexts[0].account_id,t.contexts[1].account_id])
			t.tries+=1;t.retry_at=Time.get_ticks_msec()+1000
			if queued.queued: t.ticket=queued.ticket;_jobs[queued.ticket]={"id":t.id,"kind":"receipt"}
		elif t.phase=="reconcile":
			var settled:=true
			for context: Dictionary in t.contexts:
				var peer: int=world.player_id_to_peer_id.get(context.character,0)
				if peer>0 and not _ready(peer):
					settled=false;world.wallet_runtime.retry(peer);world.inventory_runtime.repair_external_projection(peer)
			if settled: _close(t,"complete" if t.result.get("ok",false) else str(t.result.get("error","cancelled")))
	# Terminal hints are session-local; durable receipts remain the recovery source.
	for owner: int in _terminal.keys():
		if not world.player_id_to_peer_id.has(owner): _terminal.erase(owner)
func drained() -> bool: return trades.is_empty() and _jobs.is_empty()
func begin_drain() -> void: _draining=true
func shutdown_complete() -> bool: return drained()
