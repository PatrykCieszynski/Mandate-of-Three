extends RefCounted
## One local session handoff. All mutation/checkpoint/fence work is synchronous;
## do not reuse this barrier for an asynchronous or multi-World economy.
const COUNTDOWN_MS := 5000
const COMBAT_QUIET_MS := 10000
var manager: Node
var attempts: Dictionary[int, Dictionary] = {}
var _next_attempt := 0
var _next_epoch := 0

func _init(owner: Node) -> void:
	manager = owner

func snapshot(peer: int) -> Dictionary:
	var a: Dictionary = attempts.get(peer, {})
	if a.is_empty(): return {"phase":"idle"}
	return {"phase":a.phase, "attempt":a.id, "epoch":a.epoch,
		"channel_id":a.channel, "remaining_ms":maxi(0,int(a.due)-Time.get_ticks_msec()) if a.phase=="countdown" else 0,
		"error":a.get("error","")}

func gated(peer: int) -> bool:
	var a: Dictionary = attempts.get(peer,{})
	return a.get("phase","") in ["countdown","preparing","loading"] and manager._is_current_session(peer,a.session)

func _world(host: ServerInstance) -> GameWorld3D:
	return host.get_node_or_null("GameWorld") as GameWorld3D if is_instance_valid(host) else null

func _eligibility(peer: int, source: ServerInstance, now: int) -> String:
	var world := _world(source)
	if world==null or not world.characters.has(peer): return "source"
	var intent: Dictionary = world.intentions.get(peer,{})
	# Match simulation expiry: a lost release packet must not block CH forever.
	if now-int(intent.get("time",0))<=GameWorld3D.INPUT_TIMEOUT_MS and intent.get("direction",Vector2.ZERO)!=Vector2.ZERO: return "movement"
	var body: PlayerActor3D = world.characters[peer]
	if not body.alive or body.hp<=0: return "dead"
	if body.hit_reaction.locked(now) or body.knockback_active(): return "combat"
	if now-world.combat_endpoint.last_combat_ms.get(peer,-COMBAT_QUIET_MS)<COMBAT_QUIET_MS: return "combat"
	var runtime := world.combat_endpoint.attacks.attack_runtime(peer)
	if not runtime.active_action.is_empty() or not runtime.pending_impact.is_empty(): return "combat"
	if world.npc_endpoint.snapshot_for_peer(peer).get("active",false): return "interaction"
	return ""

func start(peer: int, channel: int, now: int = Time.get_ticks_msec()) -> Dictionary:
	var session: PlayerResource = manager.world_server.connected_players.get(peer)
	if not manager._is_current_session(peer,session): return {"ok":false,"error":"session"}
	var previous: Dictionary = attempts.get(peer,{})
	if not previous.is_empty() and previous.session!=session:
		release_peer(peer)
		previous={}
	if gated(peer):
		return {"ok":true} if previous.session==session and previous.channel==channel else {"ok":false,"error":"transfer_pending"}
	var source: ServerInstance = manager.world_server.request_instance(peer)
	if source==null or not source.instance_resource.use_3d or source.access_policy!=ServerInstance.AccessPolicy.PUBLIC:
		return {"ok":false,"error":"source"}
	var reason := _eligibility(peer,source,now)
	if not reason.is_empty(): return {"ok":false,"error":reason}
	var target: ServerInstance
	for candidate: ServerInstance in manager._instances_for(source.instance_resource):
		if candidate.get_parent()==manager and candidate.access_policy==ServerInstance.AccessPolicy.PUBLIC and int(candidate.identity.channel_id)==channel:
			target=candidate
			break
	if target==source: return {"ok":false,"error":"same_channel"}
	if target==null or not target.is_node_ready() or not target.accepts_reservation(): return {"ok":false,"error":"channel_unavailable"}
	_next_attempt+=1
	if previous.get("session")!=session: _next_epoch+=1
	var epoch: int = int(previous.epoch) if previous.get("session")==session else _next_epoch
	var a := {"id":_next_attempt,"epoch":epoch,"phase":"countdown","session":session,
		"source":source,"target":target,"channel":channel,"due":now+COUNTDOWN_MS,
		"origin":_world(source).characters[peer].position}
	attempts[peer]=a
	target.awaiting_peers[peer]={"session":session,"transfer_attempt":a.id,
		"expires_at_ms":a.due+int(target.instance_resource.entry_timeout_seconds*1000.0)}
	target.idle_since_ms=-1
	return {"ok":true}

func cancel(peer: int, id: int, epoch: int) -> Dictionary:
	var a: Dictionary = attempts.get(peer,{})
	if a.is_empty() or a.id!=id or a.epoch!=epoch: return {"ok":false,"error":"stale_attempt"}
	if a.phase=="aborted": return {"ok":true}
	if a.phase!="countdown": return {"ok":false,"error":"too_late"}
	_abort(peer,"cancelled")
	return {"ok":true}

func interrupt(peer: int, reason: String) -> void:
	if attempts.get(peer,{}).get("phase")=="countdown": _abort(peer,reason)

func _release(peer: int, a: Dictionary) -> void:
	var target: ServerInstance = a.target
	if is_instance_valid(target) and target.awaiting_peers.get(peer,{}).get("transfer_attempt")==a.id:
		target.awaiting_peers.erase(peer)

func _abort(peer: int, reason: String) -> void:
	var a: Dictionary = attempts[peer]
	_release(peer,a)
	a.phase="aborted"
	a.error=reason
	_publish(peer)

func release_peer(peer: int) -> void:
	if attempts.has(peer): _release(peer,attempts[peer])
	attempts.erase(peer)

func permits_join(peer: int, target: ServerInstance) -> bool:
	var a: Dictionary = attempts.get(peer,{})
	return a.get("phase")=="loading" and a.target==target and target.awaiting_peers.get(peer,{}).get("transfer_attempt")==a.id

func hydrate(peer: int, target: ServerInstance) -> Dictionary:
	if not permits_join(peer,target): return {}
	var a: Dictionary = attempts[peer]
	if not manager._is_current_session(peer,a.session): return {}
	# Consumed before any publication; repeated join cannot activate twice.
	a.phase="completed"
	var state: Dictionary = a.actor
	a.erase("actor")
	_publish(peer)
	return state

func tick(now: int = Time.get_ticks_msec()) -> void:
	for peer: int in attempts.keys():
		var a: Dictionary = attempts[peer]
		if not manager._is_current_session(peer,a.session):
			release_peer(peer)
			continue
		if a.phase!="countdown": continue
		var target: ServerInstance = a.target
		if not is_instance_valid(target) or target.get_parent()!=manager or target.is_queued_for_deletion() or target.access_policy!=ServerInstance.AccessPolicy.PUBLIC or target.admission_state!=ServerInstance.AdmissionState.ACCEPTING or target.population()>target.instance_resource.max_players or not manager.has_valid_entry(target,peer,a.session):
			_abort(peer,"channel_unavailable")
			continue
		if manager.world_server.request_instance(peer)!=a.source:
			_abort(peer,"source")
			continue
		var reason := _eligibility(peer,a.source,now)
		var world := _world(a.source)
		if reason.is_empty() and world.characters[peer].position.distance_to(a.origin)>0.25: reason="movement"
		if not reason.is_empty():
			_abort(peer,reason)
			continue
		if now<int(a.due): continue
		a.phase="preparing" # New economic intents remain closed through checkpoint.
		if manager.world_server.database==null or not manager.world_server.database.flush_character(a.session.player_id):
			_abort(peer,"checkpoint")
			continue
		var body: PlayerActor3D = world.characters[peer]
		var combo := world.combat_endpoint.combo_state(peer)
		a.actor={"position":body.position,"yaw":body.rotation.y,"hp":body.hp,"max_hp":body.max_hp,
			"skill":combo.combo_skill_level,"enabled":combo.combo_enabled,"weapon_mode":combo.weapon_mode}
		a.phase="loading" # Fence before removing source; never roll back past here.
		world.remove_peer(peer,true)
		manager._publish_entry(peer,a.session,target)
		_publish(peer)

func _publish(peer: int) -> void:
	if manager._is_current_session(peer,attempts[peer].session) and manager.world_server.multiplayer_api.get_peers().has(peer):
		manager.receive_transfer.rpc_id(peer,0,{"ok":true,"transfer":snapshot(peer)})
