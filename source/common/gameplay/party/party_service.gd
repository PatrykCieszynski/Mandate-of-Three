extends RefCounted
## World-process runtime, independent of dungeon GroupService and MapInstance ownership.
const Exp = preload("res://source/common/gameplay/party/party_exp.gd")
const Drop = preload("res://source/common/gameplay/party/party_drop.gd")
const MAX_MEMBERS = 8
const LEVEL_GAP = 15
const OFFLINE_GRACE_MS = 120000
const INVITE_MS = 30000
const ENCOUNTER_MIN_DAMAGE_PERCENT = 10
var parties: Dictionary = {}
var membership: Dictionary = {}
var invitations: Dictionary = {}
var _next_id: int = 0
var _server: Node
func _init(server: Node = null) -> void: _server=server
func peer_for(id: int) -> int:
	if _server==null: return 0
	var peer: int = _server.player_id_to_peer_id.get(id,0)
	var player = _server.connected_players.get(peer)
	return peer if player!=null and player.player_id==id and player.current_peer_id==peer else 0
func profile(id: int) -> Dictionary:
	var peer: int = peer_for(id)
	if peer>0:
		var player = _server.connected_players[peer]
		return {"id":id,"name":player.display_name,"level":player.level}
	var p: Dictionary = parties.get(membership.get(id,0),{})
	return p.get("profiles",{}).get(id,{})
func remember_disconnect(owner: int, now: int = Time.get_ticks_msec()) -> void:
	var p: Dictionary=parties.get(membership.get(owner,0),{})
	if not p.is_empty():
		p.profiles[owner]=profile(owner) # Capture a last-frame level-up before session erasure.
		p.offline[owner]=now
func sweep(now: int = Time.get_ticks_msec()) -> void:
	for target: int in invitations.keys():
		if now>=int(invitations[target].expires): invitations.erase(target)
	for pid: int in parties.keys():
		if not parties.has(pid): continue
		var p: Dictionary=parties[pid]
		for id: int in p.members.duplicate():
			if peer_for(id)>0:
				p.profiles[id]=profile(id)
				p.offline.erase(id)
			elif not p.offline.has(id): p.offline[id]=now
			elif now-int(p.offline[id])>=OFFLINE_GRACE_MS: _leave(id)
func _clear_invites(pid: int) -> void:
	for id: int in invitations.keys():
		if int(invitations[id].party)==pid: invitations.erase(id)
func _leave(id: int) -> void:
	var pid: int = membership.get(id,0)
	if not parties.has(pid): return
	var p: Dictionary=parties[pid]
	p.members.erase(id);p.profiles.erase(id);p.offline.erase(id)
	membership.erase(id)
	if p.members.is_empty(): parties.erase(pid);_clear_invites(pid)
	elif int(p.leader)==id:
		p.members.sort();p.leader=p.members[0];_clear_invites(pid)
static func valid(p: Dictionary) -> bool:
	var a = p.get("action")
	if a in ["invite","kick","leader"]: return p.size()==2 and (p.get("target") is int or p.get("target") is float) and is_finite(float(p.target)) and float(p.target)==floor(float(p.target)) and p.target>0 and p.target<=9007199254740991
	if a in ["accept","decline","leave"]: return p.size()==1
	if a=="modes": return p.size()==3 and p.get("xp_mode") in Exp.MODES and p.get("drop_mode") in Drop.MODES
	return false
func command(actor: int, request: Dictionary, now: int = Time.get_ticks_msec()) -> Dictionary:
	if not valid(request) or profile(actor).is_empty() or peer_for(actor)==0: return {"ok":false,"error":"request"}
	sweep(now)
	var action: String=request.action
	var pid: int=membership.get(actor,0)
	var p: Dictionary=parties.get(pid,{})
	if action=="invite":
		var target: int=request.target
		if target==actor or peer_for(target)==0 or membership.has(target) or invitations.has(target): return {"ok":false,"error":"target"}
		if p.is_empty():
			_next_id+=1;pid=_next_id
			p={"leader":actor,"members":[actor],"profiles":{actor:profile(actor)},"offline":{},"xp_mode":"equal","drop_mode":"round_robin","cursor":0}
		if int(p.leader)!=actor: return {"ok":false,"error":"leader"}
		if not _can_join(p,target): return {"ok":false,"error":"capacity_or_level"}
		if not parties.has(pid): parties[pid]=p;membership[actor]=pid
		invitations[target]={"party":pid,"inviter":actor,"expires":now+INVITE_MS}
	elif action in ["accept","decline"]:
		if not invitations.has(actor): return {"ok":false,"error":"invitation"}
		var invite: Dictionary=invitations[actor]
		if action=="decline": invitations.erase(actor);return {"ok":true}
		p=parties.get(int(invite.party),{})
		if membership.has(actor) or p.is_empty() or int(p.leader)!=int(invite.inviter) or not _can_join(p,actor): return {"ok":false,"error":"capacity_or_level"}
		p.members.append(actor);p.members.sort();p.profiles[actor]=profile(actor)
		membership[actor]=int(invite.party);invitations.erase(actor)
	elif action=="leave":
		if p.is_empty(): return {"ok":false,"error":"party"}
		_leave(actor)
	else:
		if p.is_empty() or int(p.leader)!=actor: return {"ok":false,"error":"leader"}
		if action=="modes": p.xp_mode=request.xp_mode;p.drop_mode=request.drop_mode
		else:
			var target: int=request.target
			if target==actor or target not in p.members: return {"ok":false,"error":"target"}
			if action=="kick": _leave(target)
			else: p.leader=target;_clear_invites(pid)
	return {"ok":true}
func _can_join(p: Dictionary, target: int) -> bool:
	if p.members.size()>=MAX_MEMBERS: return false
	var lo: int=int(profile(target).get("level",1))
	var hi: int=lo
	for id: int in p.members:
		var level: int=int(profile(id).get("level",1));lo=mini(lo,level);hi=maxi(hi,level)
	return hi-lo<=LEVEL_GAP
func record(claims: Dictionary, owner: int, damage: int) -> void:
	if owner<=0 or damage<=0: return
	var pid: int=membership.get(owner,0)
	var p: Dictionary=parties.get(pid,{})
	var key: String="solo:%d"%owner if p.is_empty() else "party:%d"%pid
	if not claims.has(key):
		claims[key]={"key":key,"party":pid,"members":[owner] if p.is_empty() else p.members.duplicate(),"damage":0,"by_id":{},"xp_mode":p.get("xp_mode","equal"),"drop_mode":p.get("drop_mode","by_damage")}
	var claim: Dictionary=claims[key]
	claim.damage+=damage;claim.by_id[owner]=claim.by_id.get(owner,0)+damage
func eligible(claim: Dictionary, world: Node3D, position: Vector3, radius: float) -> Array:
	var result: Array=[]
	for peer: int in world.characters:
		var player = world.services.player_for_peer(peer)
		if player==null or peer_for(player.player_id)!=peer or player.player_id not in claim.members: continue
		if int(claim.party)>0 and membership.get(player.player_id,0)!=int(claim.party): continue
		if world.services.transfer_pending(peer) or world.characters[peer].position.distance_to(position)>radius: continue
		result.append({"id":player.player_id,"level":player.level})
	result.sort_custom(func(a: Dictionary,b: Dictionary)->bool: return a.id<b.id)
	return result
func contenders(claims: Dictionary, world: Node3D, position: Vector3, radius: float, shared: bool) -> Array:
	var result: Array=[]
	var total: int=0
	for claim: Dictionary in claims.values(): total+=int(claim.damage)
	for claim: Dictionary in claims.values():
		var members: Array=eligible(claim,world,position,radius)
		if members.is_empty(): continue
		var entry: Dictionary=claim.duplicate(true);entry.eligible=members
		result.append(entry)
	result.sort_custom(func(a: Dictionary,b: Dictionary)->bool: return a.damage>b.damage if a.damage!=b.damage else a.key<b.key)
	if result.is_empty(): return result
	if not shared: return [result[0]]
	# A single existing pool, shared only by competitors with at least 10% damage.
	var qualified: Array=[]
	for entry: Dictionary in result:
		if int(entry.damage)*100>=total*ENCOUNTER_MIN_DAMAGE_PERCENT: qualified.append(entry)
	return qualified if not qualified.is_empty() else [result[0]]
func snapshot(owner: int, world: Node3D) -> Dictionary:
	var pid: int=membership.get(owner,0)
	var p: Dictionary=parties.get(pid,{})
	var rows: Array=[]
	for id: int in p.get("members",[]):
		var data: Dictionary=profile(id).duplicate()
		var peer: int=peer_for(id)
		var body = world.characters.get(peer)
		var same_instance: bool=body!=null
		if body==null and peer>0:
			var host = _server.request_instance(peer)
			var other = host.get_node_or_null("GameWorld") if host!=null else null
			if other!=null: body=other.characters.get(peer)
		data.merge({"online":peer>0,"same_instance":same_instance,"hp":body.hp if body!=null else 0,"max_hp":body.max_hp if body!=null else 0})
		rows.append(data)
	var candidates: Array=[]
	for peer: int in world.characters:
		var id: int=world.services.owner_id_for_peer(peer)
		if id!=owner and not membership.has(id): candidates.append(profile(id))
	candidates.sort_custom(func(a: Dictionary,b: Dictionary)->bool: return a.id<b.id)
	candidates=candidates.slice(0,64)
	var invite: Dictionary=invitations.get(owner,{})
	var incoming: Dictionary={}
	if not invite.is_empty(): incoming={"from":int(invite.inviter),"name":str(profile(int(invite.inviter)).get("name","Player"))}
	return {"id":pid,"leader":int(p.get("leader",0)),"self":owner,"xp_mode":p.get("xp_mode","equal"),"drop_mode":p.get("drop_mode","round_robin"),"members":rows,"invite":incoming,"candidates":candidates}
