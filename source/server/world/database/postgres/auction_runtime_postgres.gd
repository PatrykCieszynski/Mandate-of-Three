extends RefCounted
## World-wide bounded read scheduling, independent of mutation account lanes.
## One native read retains its slot even after timeout/disconnect until completion.
const Contract = preload("res://source/server/world/database/auction_search_contract.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const MAX_PENDING:=64
const ACCOUNT_PER_SECOND:=8
const DEADLINE_MS:=2000
var _inventory: RefCounted
var _executor: RefCounted
var _queued: Dictionary={}
var _order: Array[int]=[]
var _active: Dictionary={}
var _rates: Dictionary={}
var _draining:=false
signal observation(sample: Dictionary)

func _init(inventory: RefCounted, executor: RefCounted) -> void:
	_inventory=inventory
	_executor=executor

func submit(peer: int, key: String, payload: Dictionary, deliver: Callable, valid: Callable) -> void:
	var context: Dictionary=_inventory.context_for_peer(peer)
	if context.is_empty() or not valid.is_valid() or not valid.call(): return
	if has_pending(key): return
	var now:=Time.get_ticks_msec()
	var job: Dictionary={"peer":peer,"context":context,"key":key,"payload":payload.duplicate(true),"deliver":deliver,"valid":valid,"accepted":now,"started_us":Time.get_ticks_usec(),"terminal":false,"ticket":0}
	var built:=Contract.build_query(payload,true)
	if not built.ok: _finish(job,{"ok":false,"error":built.error});return
	if _draining: _finish(job,{"ok":false,"error":"unavailable"});return
	var account: int=context.account_id
	var rate: Dictionary=_rates.get(account,{"start":now,"count":0})
	if now-int(rate.start)>=1000: rate={"start":now,"count":0}
	rate.count+=1;_rates[account]=rate
	if rate.count>ACCOUNT_PER_SECOND: _finish(job,{"ok":false,"error":"rate_limited"});return
	if _queued.has(account):
		var previous: Dictionary=_queued[account]
		_queued.erase(account)
		_finish(previous,{"ok":false,"error":"rate_limited"})
	elif _queued.size()+(0 if _active.is_empty() else 1)>=MAX_PENDING:
		_finish(job,{"ok":false,"error":"rate_limited"});return
	else: _order.append(account)
	_queued[account]=job

func has_pending(key: String) -> bool:
	if not _active.is_empty() and _active.key==key: return true
	for job: Dictionary in _queued.values():
		if job.key==key: return true
	return false

func _current(job: Dictionary) -> bool:
	return job.valid.is_valid() and job.valid.call() and Sessions.same_context(job.context,_inventory.context_for_peer(job.peer))

func _finish(job: Dictionary, result: Dictionary) -> void:
	if job.terminal: return
	job.terminal=true
	if _current(job) and job.deliver.is_valid():
		if observation.has_connections(): observation.emit({"kind":"reply","key":job.key,"e2e_us":Time.get_ticks_usec()-int(job.started_us),"ok":result.ok,"error":result.get("error","")})
		job.deliver.call(result)

func consume(event: Dictionary) -> void:
	if _active.is_empty() or event.ticket!=_active.ticket: return
	var job:=_active
	_active={}
	if Time.get_ticks_msec()-int(job.accepted)>=DEADLINE_MS: _finish(job,{"ok":false,"error":"timeout"})
	elif not job.terminal and _current(job):
		var result: Dictionary=event.result
		if result.get("ok",false): result=Contract.project_rows(result.rows,job.payload)
		_finish(job,result)

func tick() -> void:
	var now:=Time.get_ticks_msec()
	for account: int in _rates.keys():
		if now-int(_rates[account].start)>=1000: _rates.erase(account)
	for account: int in _queued.keys():
		var job: Dictionary=_queued[account]
		if now-int(job.accepted)>=DEADLINE_MS or not _current(job):
			_queued.erase(account);_order.erase(account)
			_finish(job,{"ok":false,"error":"timeout"})
	if not _active.is_empty():
		if now-int(_active.accepted)>=DEADLINE_MS or not _current(_active): _finish(_active,{"ok":false,"error":"timeout"})
		return
	if _draining or _order.is_empty(): return
	var account: int=_order.pop_front()
	var job: Dictionary=_queued[account]
	_queued.erase(account)
	var queued: Dictionary=_executor.submit_auction_search(job.context,job.payload)
	if not queued.queued: _finish(job,{"ok":false,"error":queued.error});return
	job.ticket=queued.ticket
	_active=job

func begin_drain() -> void:
	_draining=true
	var jobs:=_queued.values()
	_queued.clear();_order.clear()
	for job: Dictionary in jobs: _finish(job,{"ok":false,"error":"unavailable"})

func drained() -> bool: return _active.is_empty() and _queued.is_empty()
