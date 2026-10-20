extends RefCounted
## Optional single-Master control owner, not a login authority of its own.
## Only existing current Master tickets can request a delegated PG grant.
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const MAX_ACCOUNTS: int=64
signal control_failed(username: String, reason: String)
var _master: WorldManagerServer
var _executor: RefCounted # Exclusive control pool; not the World runtime pool.
var _accounts: Dictionary={}
var _jobs: Dictionary={}
var _generation: int=0
var _draining:=false

func _init(master: WorldManagerServer, executor: RefCounted) -> void:
	_master=master
	_executor=executor

func request_grant(world_id: int, username: String, token: String) -> Dictionary:
	if _draining: return {"queued":false,"done":true,"result":{"ok":false,"error":"unavailable"}}
	var identity: Dictionary=_master.verified_inventory_ticket(world_id,username,token)
	if identity.is_empty(): return {"queued":false,"done":true,"result":{"ok":false,"error":"stale_session"}}
	if not _executor.is_ready(): return {"queued":false,"done":true,"result":{"ok":false,"error":"unavailable"}}
	if not _accounts.has(username) and _accounts.size()>=MAX_ACCOUNTS: return {"queued":false,"done":true,"result":{"ok":false,"error":"busy"}}
	var entry: Dictionary=_accounts.get(username,{})
	if not entry.is_empty() and entry.mode=="grant" and entry.token==token and entry.world_id==world_id and entry.identity==identity and entry.stage!="paused": return entry.request
	if not entry.is_empty(): _supersede(entry)
	_generation+=1
	var request: Dictionary={"queued":true,"done":false,"result":{}}
	var ticket: int=0 if entry.is_empty() else int(entry.ticket)
	_accounts[username]={"username":username,"world_id":world_id,"token":token,"identity":identity,"mode":"grant","generation":_generation,"stage":"inspect","ticket":ticket,"context":{},"request":request}
	return request

## Called only after Master compare-and-retire/revoke. Newer desired grants win;
## a delayed old disconnect cannot enqueue a revocation for the replacement.
func retire(username: String, token: String) -> void:
	var entry: Dictionary=_accounts.get(username,{})
	if entry.is_empty() or entry.token!=token: return
	_supersede(entry)
	_generation+=1
	entry.generation=_generation
	entry.mode="revoke"
	entry.stage="inspect"
	entry.request={"queued":true,"done":false,"result":{}}

func _supersede(entry: Dictionary) -> void:
	if not entry.request.done:
		entry.request.result={"ok":false,"error":"stale_session"}
		entry.request.done=true

func _authorized(entry: Dictionary) -> bool:
	return _master.verified_inventory_ticket(entry.world_id,entry.username,entry.token)==entry.identity

func _fail(entry: Dictionary, result: Dictionary) -> void:
	entry.stage="paused"
	entry.request.result=result.duplicate(true)
	entry.request.done=true
	control_failed.emit(entry.username,str(result.get("error","storage")))

func poll() -> void:
	for completion: Dictionary in _executor.poll():
		var job: Dictionary=_jobs.get(completion.ticket,{})
		_jobs.erase(completion.ticket)
		if job.is_empty(): continue
		var entry: Dictionary=_accounts.get(job.username,{})
		if entry.is_empty(): continue
		entry.ticket=0
		if entry.generation!=job.generation: continue # Inspect latest desired state next.
		if entry.mode=="grant" and not _authorized(entry):
			retire(entry.username,entry.token)
			continue
		var result: Dictionary=completion.result
		if not result.get("ok",false):
			_fail(entry,result) # Unknown never automatically retries the same grant.
			continue
		if job.stage=="inspect":
			entry.context=result.context
			if entry.mode=="revoke" and (result.context.is_empty() or result.context.session_fingerprint!=entry.identity.session_fingerprint or result.phase=="revoked"):
				_finish_revoke(entry)
			else: entry.stage="apply"
		elif entry.mode=="grant":
			entry.stage="done"
			entry.context=result.context
			entry.request.result=result.duplicate(true)
			entry.request.done=true
		else: _finish_revoke(entry)
	for username: String in _accounts.keys():
		var entry: Dictionary=_accounts.get(username,{})
		if entry.is_empty(): continue
		if entry.mode=="grant" and not _authorized(entry): retire(username,entry.token)
		if entry.ticket!=0 or entry.stage not in ["inspect","apply"]: continue
		var queued: Dictionary
		if entry.stage=="inspect": queued=_executor.submit_inventory_grant_inspection(entry.identity)
		elif entry.mode=="grant": queued=_executor.submit_verified_inventory_grant(entry.identity,0 if entry.context.is_empty() else int(entry.context.epoch))
		else: queued=_executor.submit_inventory_revoke(entry.context)
		if not queued.queued:
			if queued.error!="busy": _fail(entry,{"ok":false,"error":queued.error})
			continue
		entry.ticket=queued.ticket
		_jobs[queued.ticket]={"username":username,"generation":entry.generation,"stage":entry.stage}

func _finish_revoke(entry: Dictionary) -> void:
	entry.request.result={"ok":true}
	entry.request.done=true
	_accounts.erase(entry.username) # Idle logouts must not exhaust active capacity.

func begin_drain() -> void:
	_draining=true
	for username: String in _accounts.keys(): retire(username,_accounts[username].token)
func drained() -> bool: return _accounts.is_empty() and _jobs.is_empty()
