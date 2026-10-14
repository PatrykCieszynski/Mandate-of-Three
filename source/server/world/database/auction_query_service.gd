class_name AuctionQueryService
extends Node
## One main-thread World coordinator; one active native read and fair account queue.
const MAX_PENDING := 64
const ACCOUNT_PER_SECOND := 8
const DEADLINE_MS := 2000
var reader := AuctionSociReader.new()
var writer: SQLite
var path := ""
var admissions := false
var starting := false
var draining := false
var active: Dictionary = {}
var queued: Dictionary = {}
var order: Array[int] = []
var rates: Dictionary = {}

func start(database: SQLite, database_path: String) -> bool:
	if starting or draining or reader.dispatcher!=null: return false
	writer=database; path=database_path; starting=true
	var ok: bool=await reader.start(path)
	starting=false; admissions=ok
	if not ok:
		reader.stop_if_idle()
		push_error("Auction readonly reader failed readiness; search unavailable.")
	return ok

func submit(account: int, request_key: String, payload: Dictionary, deliver: Callable, valid_session: Callable) -> void:
	if account<=0 or not valid_session.is_valid() or not valid_session.call(): return
	var built:=MarketSearchSqlite.build_query(payload)
	if not built.ok:
		if valid_session.is_valid() and valid_session.call(): deliver.call({"ok":false,"error":built.error})
		return
	var now:=Time.get_ticks_msec()
	var rate: Dictionary=rates.get(account,{"start":now,"count":0})
	if now-int(rate.start)>=1000: rate={"start":now,"count":0}
	rate.count+=1;rates[account]=rate
	var job: Dictionary={"account":account,"key":request_key,"payload":payload.duplicate(true),"query":built,"accepted":now,"deliver":deliver,"valid":valid_session,"terminal":false}
	if not admissions: _finish(job,{"ok":false,"error":"storage"});return
	# Duplicate transport IDs must not settle an already accepted request twice.
	if (not active.is_empty() and active.key==request_key) or (queued.has(account) and queued[account].key==request_key): return
	if int(rate.count)>ACCOUNT_PER_SECOND: _finish(job,{"ok":false,"error":"rate_limited"});return
	if queued.has(account):
		var old: Dictionary=queued[account];queued.erase(account)
		_finish(old,{"ok":false,"error":"rate_limited"})
	elif queued.size()+(0 if active.is_empty() else 1)>=MAX_PENDING:
		_finish(job,{"ok":false,"error":"rate_limited"});return
	else: order.append(account)
	queued[account]=job

func cancel_scope(prefix: String) -> void:
	for account: int in queued.keys():
		if str(queued[account].key).begins_with(prefix):
			queued[account].terminal=true;queued.erase(account);order.erase(account)
	if not active.is_empty() and str(active.key).begins_with(prefix): active.terminal=true

func _finish(job: Dictionary, result: Dictionary) -> void:
	if job.terminal: return
	job.terminal=true
	var valid: Callable=job.valid
	var deliver: Callable=job.deliver
	if valid.is_valid() and deliver.is_valid() and valid.call(): deliver.call(result)

func _process(_delta: float) -> void:
	reader.poll()
	var now:=Time.get_ticks_msec()
	for account: int in rates.keys():
		if now-int(rates[account].start)>=1000: rates.erase(account)
	for account: int in queued.keys():
		var job: Dictionary=queued[account]
		if now-int(job.accepted)>=DEADLINE_MS or not job.valid.is_valid() or not job.valid.call():
			queued.erase(account);order.erase(account)
			_finish(job,{"ok":false,"error":"timeout"})
	if not active.is_empty():
		if now-int(active.accepted)>=DEADLINE_MS: _finish(active,{"ok":false,"error":"timeout"})
		return # A timed-out SQL still owns the native slot until it actually finishes.
	if (not admissions and not draining) or starting or not reader.ready or order.is_empty(): return
	var account: int=order.pop_front()
	active=queued[account];queued.erase(account)
	_run(active)

func _run(job: Dictionary) -> void:
	var answer: Dictionary=await reader.query(job.query.sql,job.query.params,int(job.payload.limit)+1)
	if Time.get_ticks_msec()-int(job.accepted)>=DEADLINE_MS: _finish(job,{"ok":false,"error":"timeout"})
	elif not job.terminal and job.valid.is_valid() and job.valid.call():
		var result:=MarketSearchSqlite.project_rows(answer.rows,job.payload,writer) if answer.get("ok",false) and not answer.get("truncated",false) else {"ok":false,"error":"storage"}
		if Time.get_ticks_msec()-int(job.accepted)>=DEADLINE_MS: result={"ok":false,"error":"timeout"}
		_finish(job,result)
	active={}
	if not answer.get("ok",false):
		admissions=false
		for account: int in queued.keys(): _finish(queued[account],{"ok":false,"error":"storage"})
		queued.clear();order.clear()
		reader.stop_if_idle()

func pause(budget_ms: int = DEADLINE_MS) -> bool:
	if draining or starting: return false
	admissions=false;draining=true
	var deadline:=Time.get_ticks_msec()+budget_ms
	while not active.is_empty() or not queued.is_empty() or reader.pending()!=0:
		if Time.get_ticks_msec()>=deadline:
			draining=false # Refuse backup/shutdown; keep polling the live native read.
			return false
		await get_tree().process_frame
	var ok:=reader.stop_if_idle()
	draining=false
	return ok
