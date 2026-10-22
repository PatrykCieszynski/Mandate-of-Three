extends RefCounted
## Optional single-World ground-item delivery. No SQL or durable RAM queue.
## Unknown execution is resolved by read-only receipt lookup, never auto-retried.
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const MAX_ACTIVE: int=64 # Includes detached accounts with unknown outcomes.
signal finished(peer: int, ground: RefCounted, operation_id: String, result: Dictionary)
signal committed(peer: int, ground: RefCounted)
var _inventory: RefCounted
var _executor: RefCounted
var _active: Dictionary={}
var _jobs: Dictionary={}
var _draining:=false
var _serial: int=0
var _deferred_recovery: Array[Dictionary]=[]

func _init(inventory: RefCounted, executor: RefCounted) -> void:
	_inventory=inventory
	_executor=executor
	_inventory.enable_initialization()

func pickup(peer: int, ground: GroundLootSystem, uid: String, now: int) -> Dictionary:
	if _draining: return {"queued":false,"error":"unavailable"}
	if not ItemInstance.valid_uid(uid): return {"queued":false,"error":"gone"}
	var context: Dictionary=_inventory.context_for_peer(peer)
	if context.is_empty(): return {"queued":false,"error":"stale_session"}
	var active: Dictionary=_active.get(context.account_id,{})
	if not active.is_empty():
		if active.id!=uid: return {"queued":false,"error":"operation_pending"}
		return receipt(peer,uid)
	# A missing runtime drop can only initiate read-only receipt discovery. It
	# cannot reconstruct arbitrary loot or execute a client-supplied item body.
	if not ground.drops.has(uid): return _begin(peer,uid,ground,{},true)
	var candidate:=ground.claim_candidate(peer,uid,now)
	if not candidate.ok: return {"queued":false,"error":candidate.error}
	if ground.pending_claims.has(uid): return {"queued":false,"error":"operation_pending"}
	return _begin(peer,uid,ground,candidate.drop,false)

func receipt(peer: int, id: String) -> Dictionary:
	if _draining: return {"queued":false,"error":"unavailable"}
	if not ItemInstance.valid_uid(id): return {"queued":false,"error":"request"}
	var context: Dictionary=_inventory.context_for_peer(peer)
	if context.is_empty(): return {"queued":false,"error":"stale_session"}
	var active: Dictionary=_active.get(context.account_id,{})
	if active.is_empty(): return {"queued":false,"error":"unknown_command"}
	if active.id!=id or active.ticket!=0: return {"queued":false,"error":"operation_pending"}
	active.peer=peer
	active.context=context
	active.repairs=0
	if active.stage=="reconcile": _repair(active)
	else:
		active.stage="receipt"
		_schedule(active)
	return {"queued":true}

func _begin(peer: int, id: String, ground: GroundLootSystem, body: Dictionary, lookup: bool) -> Dictionary:
	if _draining or not ItemInstance.valid_uid(id): return {"queued":false,"error":"request"}
	var context: Dictionary=_inventory.context_for_peer(peer)
	if context.is_empty(): return {"queued":false,"error":"stale_session"}
	if _active.size()>=MAX_ACTIVE: return {"queued":false,"error":"busy"}
	if _active.has(context.account_id) or not _inventory.hold_external(peer,"ground:"+id): return {"queued":false,"error":"recovery_required"}
	_serial+=1
	var active: Dictionary={"serial":_serial,"account":context.account_id,"peer":peer,"context":context,"id":id,"ground":ground,"body":body.duplicate(true),"stage":"receipt" if lookup else "execute","ticket":0,"result":{},"changed":false,"repairs":0,"retry_at":0}
	_active[context.account_id]=active
	if not lookup: ground.pending_claims[id]=true
	_schedule(active)
	return {"queued":true} # Volatile scheduling; the drop UID is the retry identity.

func _schedule(active: Dictionary) -> void:
	var queued: Dictionary=_executor.submit_ground_claim(active.context,active.id,active.body) if active.stage=="execute" else _executor.submit_ground_receipt(active.context,active.id)
	if not queued.queued:
		if active.stage=="execute": _settle(active,{"ok":false,"error":queued.error})
		else: _pause(active,str(queued.error))
		return
	active.ticket=queued.ticket
	_jobs[queued.ticket]=active.account

func _pause(active: Dictionary, reason: String) -> void:
	active.stage="paused"
	active.reason=reason
	active.retry_at=Time.get_ticks_msec()+1000
	_failure.call_deferred(active.account,active.serial,active.peer,reason)

func _failure(account: int, serial: int, peer: int, reason: String) -> void:
	var active: Dictionary=_active.get(account,{})
	if not active.is_empty() and active.serial==serial and active.peer==peer and active.stage=="paused": finished.emit(peer,active.ground,active.id,{"ok":false,"error":reason})

func _settle(active: Dictionary, result: Dictionary) -> void:
	if result.get("ok",false) and not active.body.is_empty():
		var definition:=ItemDefinitions.get_definition(StringName(active.body.definition_id))
		if definition!=null:
			result=result.duplicate(true)
			result.merge({"item_name":definition.item_name,"amount":int(active.body.amount),"weapon_attack":GroundLootSystem.attack_for_drop(definition,active.body)})
	if result.get("ok",false) or result.get("error","")=="claimed": active.ground.drops.erase(active.id)
	active.ground.pending_claims.erase(active.id)
	_inventory.finish_external(active.account,"ground:"+active.id,result.get("item_state",{}))
	active.result=result.duplicate(true)
	active.stage="reconcile"
	active.repairs=0
	active.retry_at=0

func _repair(active: Dictionary) -> void:
	if _inventory.repair_external_projection(active.peer):
		active.repairs+=1
		active.retry_at=Time.get_ticks_msec()+1000

func poll() -> void:
	for event: Dictionary in _executor.poll():
		if not _jobs.has(event.ticket): continue
		var active: Dictionary=_active.get(_jobs[event.ticket],{})
		_jobs.erase(event.ticket)
		if active.is_empty(): continue
		active.ticket=0
		active.changed=active.changed or (event.get("committed",false) and not event.get("receipt_replay",false))
		var result: Dictionary=event.result
		if not result.get("ok",false) and result.get("error","") in ["storage","outcome_unknown","stale_session","session_required","recovery_required"]: _pause(active,str(result.error))
		elif result.get("error","")=="claimed" and event.intent=="ground_claim":
			active.stage="receipt"
			_schedule(active)
		else: _settle(active,result)
	for account: int in _active.keys():
		var active: Dictionary=_active[account]
		var binding: Dictionary=_inventory.binding(account)
		if not binding.is_empty():
			var replaced: bool=not Sessions.same_context(active.context,binding.context)
			active.peer=binding.peer
			active.context=binding.context
			if replaced and active.stage=="paused": active.retry_at=0;active.repairs=0
		if active.stage=="reconcile":
			if binding.is_empty(): _active.erase(account)
			elif _inventory.mutations_allowed(active.peer):
				if active.changed:
					active.changed=false
					committed.emit(active.peer,active.ground)
				var current: Dictionary=_inventory.binding(account)
				if not current.is_empty() and current.peer==active.peer and Sessions.same_context(current.context,active.context) and _inventory.mutations_allowed(active.peer):
					_active.erase(account)
					finished.emit(active.peer,active.ground,active.id,active.result)
			elif not _draining and active.repairs<3 and Time.get_ticks_msec()>=active.retry_at: _repair(active)
		elif not _draining and active.stage=="paused" and not binding.is_empty() and active.repairs<3 and Time.get_ticks_msec()>=active.retry_at:
			active.repairs+=1
			active.stage="receipt"
			_schedule(active)

func begin_drain() -> void:
	_draining=true
	# Finish every already-enqueued whole transaction, then close its session.
	# No forced SQL cancellation and no new recovery jobs while stopping.
	_executor.begin_drain()

## Operator diagnostics contain no tokens, connection strings or item bodies.
## Ground loot has no RAM persistent money/value to flush. Once all native jobs/sessions have
## ended, unknown outcomes can safely be discovered from receipts on reconnect.
func drain_status() -> Dictionary:
	var pending: Array=[]
	for active: Dictionary in _active.values():
		pending.append({"account_id":active.account,"operation_id":active.id,"stage":active.stage,"reason":active.get("reason",""),"attempts":active.repairs})
	return {"draining":_draining,"in_flight":_jobs.size(),"worker_stopped":_executor.is_stopped(),"safe_to_stop":_draining and _jobs.is_empty() and _executor.is_stopped(),"pending":pending,"recover_on_reconnect":_deferred_recovery.duplicate(true)}

func drained() -> bool: return _active.is_empty() and _jobs.is_empty()
func shutdown_complete() -> bool:
	if not _draining or not _jobs.is_empty() or not _executor.is_stopped(): return false
	for active: Dictionary in _active.values():
		active.ground.pending_claims.erase(active.id)
		_deferred_recovery.append({"account_id":active.account,"operation_id":active.id,"stage":active.stage,"reason":active.get("reason","")})
		_inventory.finish_external(active.account,"ground:"+active.id,active.result.get("item_state",{}))
	if not _active.is_empty():
		push_warning("Ground item drain: native workers stopped; %d unfinished deliveries deferred to receipt discovery on reconnect. Details: ground_item_runtime.drain_status().recover_on_reconnect" % _active.size())
	_active.clear()
	return true
