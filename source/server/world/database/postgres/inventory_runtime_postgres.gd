extends RefCounted
## Opt-in World-thread Inventory delivery/recovery owner. Not a backend selector,
## grant issuer or RPC endpoint. Owns polling an already started executor.
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Versions = preload("res://source/common/gameplay/items/domain/item_state_version.gd")
const MAX_BINDINGS: int=64
const PAGE_SIZE: int=32
const MAX_REPAIRS: int=3
signal snapshot_applied(peer_id: int, snapshot: Dictionary)
signal ready_changed(peer_id: int, ready: bool)
signal operation_admitted(peer_id: int, operation_id: String)
signal operation_finished(peer_id: int, operation_id: String, result: Dictionary)
signal recovery_failed(peer_id: int, reason: String)
signal inventory_committed(peer_id: int)
var _world: WorldServer
var _executor: RefCounted
var _bindings: Dictionary={}
var _jobs: Dictionary={}
var _generation: int=0

func _init(world: WorldServer, executor: RefCounted) -> void:
	_world=world
	_executor=executor

## The context must already be installed by the privileged verified-grant owner.
## Native World authentication proves the peer/ticket; PostgreSQL proves the
## account/character/epoch grant on every recovery/admission transaction.
func attach(peer_id: int, context: Dictionary) -> bool:
	if not Sessions.valid_identity(context) or not context.get("epoch") is int or context.epoch<=0: return false
	if _world.session_ticket_fingerprint(peer_id,int(context.character))!=context.session_fingerprint: return false
	if not _bindings.has(context.account_id) and _bindings.size()>=MAX_BINDINGS: return false
	var previous: Dictionary=_bindings.get(context.account_id,{})
	# Repeated lifecycle delivery is not a new session. Preserve the original
	# command/body, outstanding ticket and paused/unknown recovery state.
	if not previous.is_empty() and previous.peer==peer_id and Sessions.same_context(previous.context,context): return true
	_generation+=1
	var safe: Dictionary={"account_id":context.account_id,"character":context.character,"session_fingerprint":context.session_fingerprint,"epoch":context.epoch}
	var binding: Dictionary={"peer":peer_id,"context":safe,"generation":_generation,"stage":"discover","ticket":0,"cursor":0,"pending":[],"more":false,"repairs":0,"command":{},"retry":false,"snapshot":{},"terminal":{},"changed":false,"required":{}}
	_bindings[safe.account_id]=binding
	if not previous.is_empty(): ready_changed.emit(previous.peer,false)
	if _still_bound(binding): ready_changed.emit(peer_id,false)
	return true

func detach(peer_id: int) -> void:
	for account: int in _bindings.keys():
		if _bindings[account].peer==peer_id:
			_bindings.erase(account)
			ready_changed.emit(peer_id,false)
	# Queued SQL is not cancelled. Captured jobs remain bounded by the executor
	# and are consumed/discarded; a replacement recovers durable work from PG.

func _current(binding: Dictionary) -> bool:
	return _world.session_ticket_fingerprint(binding.peer,binding.context.character)==binding.context.session_fingerprint

func _for_peer(peer_id: int) -> Dictionary:
	for binding: Dictionary in _bindings.values():
		if binding.peer==peer_id and _current(binding): return binding
	return {}

func mutations_allowed(peer_id: int) -> bool:
	var binding:=_for_peer(peer_id)
	return not binding.is_empty() and binding.stage=="ready"

func status(peer_id: int) -> String:
	var binding:=_for_peer(peer_id)
	return "detached" if binding.is_empty() else str(binding.stage)

func snapshot_for_peer(peer_id: int) -> Dictionary:
	var binding:=_for_peer(peer_id)
	return {} if binding.is_empty() else binding.snapshot.duplicate(true)

## Trusted application-side committed marker only, NOT a client RPC. Revisions
## are account-wide: an alt's mutation can invalidate this character's view.
## Coalesce notices into a floor; never enqueue work per notification or cancel SQL.
func invalidate_item_state(marker: Dictionary) -> bool:
	if not Versions.valid(marker): return false
	var binding: Dictionary=_bindings.get(marker.account_id,{})
	if binding.is_empty() or not _current(binding): return false
	var known: Dictionary=binding.snapshot.get("item_state",{})
	if not binding.required.is_empty() and (known.is_empty() or binding.required.revision>known.revision): known=binding.required
	if not known.is_empty():
		if marker.authority_id!=known.authority_id:
			_pause(binding,"authority_mismatch")
			return false
		if marker.revision<=known.revision: return true # Old/duplicate notice.
	binding.required=marker.duplicate(true)
	_world.invalidate_runtime_equipment(binding.context.character)
	if binding.stage=="ready":
		binding.repairs=0
		_restart_recovery(binding)
	ready_changed.emit(binding.peer,false)
	return true

func _satisfies_floor(binding: Dictionary, marker: Dictionary) -> bool:
	var required: Dictionary=binding.required
	return required.is_empty() or (marker.authority_id==required.authority_id and marker.account_id==required.account_id and marker.revision>=required.revision)

func _repair(binding: Dictionary, reason: String) -> void:
	if binding.repairs>=MAX_REPAIRS:
		_pause(binding,reason)
		return
	binding.repairs+=1
	_restart_recovery(binding)

## Receipt discovery never invents a body or admits a missing command. Pending
## durable work may finish; unknown IDs are returned to the caller for an
## explicit same-ID/body retry. Also repairs a paused/uncertain binding first.
func request_outcome(peer_id: int, operation_id: String) -> Dictionary:
	var binding:=_for_peer(peer_id)
	if binding.is_empty(): return {"queued":false,"error":"stale_session"}
	if not Commands.valid_id(operation_id): return {"queued":false,"error":"request"}
	if binding.ticket!=0: return {"queued":false,"error":"operation_pending"}
	if binding.stage not in ["ready","paused"]: return {"queued":false,"error":"operation_pending"}
	if not binding.command.is_empty() and binding.command.id!=operation_id: return {"queued":false,"error":"recovery_required"}
	if binding.command.is_empty(): binding.command={"id":operation_id}
	binding.retry=false
	binding.repairs=0
	if binding.stage=="paused": _restart_recovery(binding)
	else: binding.stage="outcome"
	ready_changed.emit(peer_id,false)
	return {"queued":true}

func submit(peer_id: int, operation_id: String, action: String, uid: String, revision: int, position: int) -> Dictionary:
	var binding:=_for_peer(peer_id)
	if binding.is_empty(): return {"queued":false,"error":"stale_session"}
	if binding.stage!="ready": return {"queued":false,"error":"recovery_required"}
	if not Commands.valid_id(operation_id) or not Items.valid_inventory_request(action,uid,revision,position): return {"queued":false,"error":"request"}
	binding.command={"id":operation_id,"action":action,"uid":uid,"revision":revision,"position":position}
	binding.stage="admit"
	binding.repairs=0
	ready_changed.emit(peer_id,false)
	# RAM scheduling only. operation_admitted is emitted after durable ACK.
	return {"queued":true}

## Explicit caller recovery after storage/COMMIT uncertainty. No automatic
## retry of an uncertain mutation; original ID/body stays in this binding.
func retry(peer_id: int) -> bool:
	var binding:=_for_peer(peer_id)
	if binding.is_empty() or binding.stage!="paused" or binding.ticket!=0: return false
	binding.retry=binding.command.has_all(["action","uid","revision","position"])
	binding.repairs=0
	_restart_recovery(binding)
	return true

func _restart_recovery(binding: Dictionary) -> void:
	binding.stage="discover"
	binding.cursor=0
	binding.pending=[]
	binding.more=false

func _pause(binding: Dictionary, reason: String) -> void:
	binding.stage="paused"
	_world.invalidate_runtime_equipment(binding.context.character)
	ready_changed.emit(binding.peer,false)
	recovery_failed.emit(binding.peer,reason)

## Caller invokes on the World thread. No SQL/await/wait-to-finish here.
func poll() -> void:
	for completion: Dictionary in _executor.poll():
		var job: Dictionary=_jobs.get(completion.ticket,{})
		_jobs.erase(completion.ticket)
		if job.is_empty(): continue
		var binding: Dictionary=_bindings.get(job.account,{})
		if binding.is_empty() or binding.generation!=job.generation: continue
		binding.ticket=0
		if not _current(binding) or not Sessions.same_context(completion.session,binding.context):
			detach(binding.peer)
			continue
		if binding.stage=="paused": continue # Drain, never revive an invalidated lane.
		if job.stage in ["resume","recover"] and completion.get("committed",false) and not completion.get("receipt_replay",false): binding.changed=true
		_complete(binding,job.stage,completion.result)
	for account: int in _bindings.keys():
		var binding: Dictionary=_bindings.get(account,{})
		if binding.is_empty(): continue
		if not _current(binding):
			detach(binding.peer)
			continue
		if binding.ticket==0 and binding.stage not in ["ready","paused"]: _schedule(binding)

func _schedule(binding: Dictionary) -> void:
	var context: Dictionary=binding.context
	var queued: Dictionary
	match binding.stage:
		"discover": queued=_executor.submit_session_discovery(context,binding.cursor,PAGE_SIZE)
		"recover": queued=_executor.submit_session_resume(context,binding.pending[0])
		"snapshot", "refresh": queued=_executor.submit_session_snapshot(context)
		"ack": queued=_executor.submit_inventory_recovery_ready(context,binding.snapshot.item_state)
		"admit":
			var command: Dictionary=binding.command
			queued=_executor.submit_session_inventory(context,command.id,command.action,command.uid,command.revision,command.position)
		"resume": queued=_executor.submit_session_resume(context,binding.command.id)
		"outcome": queued=_executor.submit_session_outcome(context,binding.command.id)
		_: return
	if not queued.queued:
		if queued.error!="busy": _pause(binding,str(queued.error))
		return # No extra unbounded work queue on top of the bounded executor.
	binding.ticket=queued.ticket
	_jobs[queued.ticket]={"account":context.account_id,"generation":binding.generation,"stage":binding.stage}

func _complete(binding: Dictionary, stage: String, result: Dictionary) -> void:
	if not result.get("ok",false):
		var reason: String=str(result.get("error","storage"))
		if stage=="ack" and reason in ["operations_pending","stale_snapshot"]:
			_repair(binding,reason)
		elif stage=="outcome" and reason=="unknown_command" and binding.retry:
			binding.stage="admit" # Explicit same-ID retry after outcome discovery.
			binding.retry=false
		elif stage=="outcome" and reason=="unknown_command":
			binding.terminal=result.duplicate(true)
			binding.stage="refresh" # A missing receipt cannot bypass reconciliation.
		else: _pause(binding,reason)
		return
	match stage:
		"discover":
			binding.cursor=result.cursor
			binding.more=result.more
			binding.pending=[]
			for operation: Dictionary in result.operations:
				if operation.state=="pending": binding.pending.append(operation.operation_id)
			_next_page(binding)
		"recover":
			if result.get("state","") not in ["committed","rejected"]:
				_pause(binding,"operation_pending")
				return
			binding.pending.pop_front()
			_next_page(binding)
		"snapshot", "refresh":
			var marker: Variant=result.get("item_state")
			if not Versions.valid(marker) or marker.account_id!=binding.context.account_id or marker.character_id!=binding.context.character:
				_pause(binding,"snapshot_identity")
				return
			if not _satisfies_floor(binding,marker):
				_repair(binding,"stale_snapshot")
				return
			if not _world.update_runtime_equipment(binding.context.character,result):
				_pause(binding,"snapshot_rejected")
				return
			binding.snapshot=result.duplicate(true)
			snapshot_applied.emit(binding.peer,result.duplicate(true))
			# Signal handlers may detach/replace the binding. Never acknowledge or
			# finish another session as a consequence of that callback.
			if not _still_bound(binding) or binding.stage=="paused": return
			binding.stage="ack" # Both entry AND post-command refresh need backend ACK.
		"ack":
			# A newer committed notice can arrive after SQL ACK but before delivery.
			if not _satisfies_floor(binding,binding.snapshot.item_state):
				_repair(binding,"stale_snapshot")
			elif binding.command.is_empty() or not binding.terminal.is_empty(): _finish_ready(binding)
			else: binding.stage="outcome"
		"admit", "resume", "outcome":
			if result.get("state","")=="pending":
				binding.stage="resume"
				if stage=="admit": operation_admitted.emit(binding.peer,binding.command.id)
			elif result.get("state","") in ["committed","rejected"]:
				binding.terminal=result.result.duplicate(true)
				binding.stage="refresh" # Rehydrate before any terminal publication.
			else: _pause(binding,"invalid_outcome")

func _finish_ready(binding: Dictionary) -> void:
	var command: Dictionary=binding.command
	var terminal: Dictionary=binding.terminal
	if binding.changed:
		binding.changed=false
		inventory_committed.emit(binding.peer)
		if not _still_bound(binding) or binding.stage=="paused": return
		if not _satisfies_floor(binding,binding.snapshot.item_state):
			_repair(binding,"stale_snapshot")
			return
	binding.command={}
	binding.terminal={}
	binding.stage="ready"
	ready_changed.emit(binding.peer,true)
	if _still_bound(binding) and binding.stage=="ready" and not command.is_empty(): operation_finished.emit(binding.peer,command.id,terminal.duplicate(true))

func _next_page(binding: Dictionary) -> void:
	binding.stage="recover" if not binding.pending.is_empty() else ("discover" if binding.more else "snapshot")

func _still_bound(binding: Dictionary) -> bool:
	var live: Dictionary=_bindings.get(binding.context.account_id,{})
	return not live.is_empty() and live.generation==binding.generation and _current(binding)
