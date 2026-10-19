extends RefCounted
## Optional single-World seller/claim delivery. No SQL or durable RAM queue.
## Unknown execution is resolved by read-only receipt lookup, never auto-retried.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Content = preload("res://source/server/world/database/postgres/seller_session_postgres.gd")
const Versions = preload("res://source/common/gameplay/items/domain/item_state_version.gd")
const MAX_ACTIVE: int=64 # Includes detached accounts with unknown outcomes.
signal finished(peer: int, operation_id: String, result: Dictionary)
signal committed(peer: int, action: String)
signal snapshot_applied(peer: int, snapshot: Dictionary)
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

func open(peer: int) -> Dictionary:
	if _draining: return {"queued":false,"error":"unavailable"}
	var context: Dictionary=_inventory.context_for_peer(peer)
	var active: Dictionary=_active.get(context.get("account_id",0),{})
	if not active.is_empty() and active.action=="open" and active.stage=="paused" and active.ticket==0:
		active.peer=peer
		active.context=context
		active.repairs=0
		active.stage="snapshot"
		_schedule(active)
		return {"queued":true}
	return _begin(peer,"view:"+Crypto.new().generate_random_bytes(16).hex_encode(),"open",{},true)

func submit(peer: int, action: String, body: Dictionary) -> Dictionary:
	if action not in Content.ACTIONS or not MarketRequestRules.valid_command(action,body): return {"queued":false,"error":"unsupported"}
	return _begin(peer,body.command_id,action,body,false)

func receipt(peer: int, id: String) -> Dictionary:
	if _draining: return {"queued":false,"error":"unavailable"}
	if not Commands.valid_id(id): return {"queued":false,"error":"request"}
	var context: Dictionary=_inventory.context_for_peer(peer)
	if context.is_empty(): return {"queued":false,"error":"stale_session"}
	var active: Dictionary=_active.get(context.account_id,{})
	if active.is_empty(): return _begin(peer,id,"receipt",{},true)
	if active.id!=id or active.ticket!=0: return {"queued":false,"error":"operation_pending"}
	active.peer=peer
	active.context=context
	active.repairs=0
	if active.stage=="reconcile": _repair(active)
	elif not active.result.is_empty():
		active.stage="snapshot"
		_schedule(active)
	else:
		active.stage="receipt"
		_schedule(active)
	return {"queued":true}

func _begin(peer: int, id: String, action: String, body: Dictionary, lookup: bool) -> Dictionary:
	if _draining or not Commands.valid_id(id): return {"queued":false,"error":"request"}
	var context: Dictionary=_inventory.context_for_peer(peer)
	if context.is_empty(): return {"queued":false,"error":"stale_session"}
	if _active.size()>=MAX_ACTIVE: return {"queued":false,"error":"busy"}
	if _active.has(context.account_id) or not _inventory.hold_external(peer,"seller:"+id): return {"queued":false,"error":"recovery_required"}
	_serial+=1
	var active: Dictionary={"serial":_serial,"account":context.account_id,"peer":peer,"context":context,"id":id,"action":action,"snapshot":{},"published":false,"body":body.duplicate(true),"stage":"snapshot" if action=="open" else ("receipt" if lookup else "execute"),"ticket":0,"result":{},"changed":false,"repairs":0,"retry_at":0}
	_active[context.account_id]=active
	_schedule(active)
	return {"queued":true} # Volatile scheduling only, client keeps its journal.

func _schedule(active: Dictionary) -> void:
	var queued: Dictionary
	if active.stage=="execute": queued=_executor.submit_seller(active.context,active.action,active.body)
	elif active.stage=="snapshot": queued=_executor.submit_seller_snapshot(active.context)
	else: queued=_executor.submit_seller_receipt(active.context,active.id)
	if not queued.queued:
		if active.stage=="execute": _settle(active,{"ok":false,"error":queued.error})
		else: _pause(active,str(queued.error))
		return
	active.ticket=queued.ticket
	_jobs[queued.ticket]=active.account

func _pause(active: Dictionary, reason: String) -> void:
	active.failed_stage=active.stage
	active.stage="paused"
	active.reason=reason
	active.retry_at=Time.get_ticks_msec()+1000
	_failure.call_deferred(active.account,active.serial,active.peer,reason)

func _failure(account: int, serial: int, peer: int, reason: String) -> void:
	var active: Dictionary=_active.get(account,{})
	if not active.is_empty() and active.serial==serial and active.peer==peer and active.stage=="paused": finished.emit(peer,active.id,{"ok":false,"error":reason})

func _settle(active: Dictionary, result: Dictionary) -> void:
	_inventory.finish_external(active.account,"seller:"+active.id,result.get("item_state",{}))
	active.result=result.duplicate(true)
	active.stage="snapshot"
	active.repairs=0
	_schedule(active)
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
		if not result.get("ok",false) and (event.intent=="seller_snapshot" or result.get("error","") in ["storage","outcome_unknown","stale_session","session_required","recovery_required"]): _pause(active,str(result.error))
		elif event.intent=="seller_snapshot":
			active.snapshot=result.duplicate(true)
			if active.action=="open":
				_inventory.finish_external(active.account,"seller:"+active.id)
				active.result={"ok":true}
			active.stage="reconcile"
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
				var marker: Dictionary=active.snapshot.get("item_state",{})
				var current_marker: Dictionary=_inventory.snapshot_for_peer(active.peer).get("item_state",{})
				if not Versions.valid(marker) or not Versions.valid(current_marker) or marker.authority_id!=current_marker.authority_id or marker.account_id!=current_marker.account_id:
					_pause(active,"storage")
					continue
				if marker.revision!=current_marker.revision:
					if active.repairs>=3: _pause(active,"storage")
					else:
						active.repairs+=1
						if marker.revision>current_marker.revision: _inventory.invalidate_item_state(marker)
						else:
							active.stage="snapshot"
							_schedule(active)
					continue
				if not active.published:
					active.published=true
					snapshot_applied.emit(active.peer,active.snapshot.duplicate(true))
					var current_projection: Dictionary=_inventory.binding(account)
					if current_projection.is_empty() or current_projection.peer!=active.peer or not Sessions.same_context(current_projection.context,active.context) or not _inventory.mutations_allowed(active.peer): continue
				if active.changed:
					active.changed=false
					committed.emit(active.peer,active.action)
				var current: Dictionary=_inventory.binding(account)
				if not current.is_empty() and current.peer==active.peer and Sessions.same_context(current.context,active.context) and _inventory.mutations_allowed(active.peer):
					_active.erase(account)
					finished.emit(active.peer,active.id,active.result)
			elif not _draining and active.repairs<3 and Time.get_ticks_msec()>=active.retry_at: _repair(active)
		elif not _draining and active.stage=="paused" and not binding.is_empty() and active.repairs<3 and Time.get_ticks_msec()>=active.retry_at:
			active.repairs+=1
			active.stage="snapshot" if active.get("failed_stage","")=="snapshot" else "receipt"
			_schedule(active)

func begin_drain() -> void:
	_draining=true
	# Finish every already-enqueued whole transaction, then close its session.
	# No forced SQL cancellation and no new recovery jobs while stopping.
	_executor.begin_drain()

## Operator diagnostics contain no tokens, connection strings or item bodies.
## Seller custody has no RAM money/value to flush. Once all native jobs/sessions have
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
		_deferred_recovery.append({"account_id":active.account,"operation_id":active.id,"stage":active.stage,"reason":active.get("reason","")})
		_inventory.finish_external(active.account,"seller:"+active.id,active.result.get("item_state",{}))
	if not _active.is_empty():
		push_warning("Seller drain: native workers stopped; %d unfinished deliveries deferred to receipt discovery on reconnect. Details: seller_runtime.drain_status().recover_on_reconnect" % _active.size())
	_active.clear()
	return true
