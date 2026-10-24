extends RefCounted
## Opt-in server-local execution boundary, NOT durable admission or a World API.
## Main-thread caller polls copied results. Each worker owns its native session
## from open through full store transaction/retry to close; no async SQL hopping.
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Intents = preload("res://source/server/world/database/postgres/inventory_intent_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const WalletSession = preload("res://source/server/world/database/postgres/wallet_session_postgres.gd")
const TradeStore = preload("res://source/server/world/database/postgres/player_trade_store_postgres.gd")
const NpcSession = preload("res://source/server/world/database/postgres/npc_session_postgres.gd")
const StorageSession = preload("res://source/server/world/database/postgres/storage_session_postgres.gd")
const GroundSession = preload("res://source/server/world/database/postgres/ground_item_session_postgres.gd")
const Identity = preload("res://source/server/world/database/postgres/identity_bootstrap_postgres.gd")
const Preflight = preload("res://source/server/world/database/postgres/economy_preflight_postgres.gd")
const AuctionSession = preload("res://source/server/world/database/postgres/auction_session_postgres.gd")
const SellerSession = preload("res://source/server/world/database/postgres/seller_session_postgres.gd")
enum State { STOPPED = 0, STARTING = 1, RUNNING = 2, DRAINING = 3 }
const MAX_WORKERS: int=4
const MAX_CAPACITY_PER_WORKER: int=16
var state: State=State.STOPPED
var startup_error: String=""
var _slots: Array=[]
var _pending: Dictionary={}
var _capacity: int
var _next_ticket: int=0
var _ready_count: int=0
## Opt-in local diagnostics, never part of RPC/results or persistent receipts.
## Disabled by default: no per-job clock reads or sample allocation.
var profiling_enabled:=false
signal observation(sample: Dictionary)

class SessionWorker extends RefCounted:
	var _connection: String
	var _mutex:=Mutex.new()
	var _wake:=Semaphore.new()
	var _queue: Array=[]
	var _events: Array=[]
	var _closing:=false

	func _init(connection: String) -> void:
		_connection=connection

	func enqueue(job: Dictionary) -> void:
		_mutex.lock()
		_queue.append(job.duplicate(true))
		_mutex.unlock()
		_wake.post()

	func drain() -> void:
		_mutex.lock()
		_closing=true
		_mutex.unlock()
		_wake.post()

	func take_events() -> Array:
		_mutex.lock()
		var events:=_events
		_events=[]
		_mutex.unlock()
		return events

	func _publish(event: Dictionary) -> void:
		_mutex.lock()
		_events.append(event.duplicate(true))
		_mutex.unlock()

	func _open(database: Object) -> bool:
		if not database.open("postgresql",_connection): return false
		# Server-side SQL budgets, not cancellation or a hard network deadline.
		for setting: String in ["SET statement_timeout=2000;","SET lock_timeout=1000;","SET idle_in_transaction_session_timeout=5000;"]:
			if not database.execute(setting).ok:
				database.close()
				return false
		return true

	func run() -> void:
		var database: Object=ClassDB.instantiate("GodotSociDatabase")
		var opened: bool=_open(database)
		_publish({"kind":"ready","ok":opened})
		if not opened:
			database.close()
			return
		while true:
			_wake.wait()
			_mutex.lock()
			var stop: bool=_closing and _queue.is_empty()
			var job: Dictionary={} if _queue.is_empty() else _queue.pop_front()
			_mutex.unlock()
			if stop: break
			if job.is_empty(): continue
			var started: int=Time.get_ticks_usec() if job.has("queued_us") else 0
			var result: Dictionary={"ok":false,"error":"storage"}
			var committed:=false
			var replay:=false
			if database.is_open() or _open(database):
				var intent: String=str(job.get("intent",""))
				var store: RefCounted
				if intent in ["identity_bind","profile_bind"]: store=Identity.new(database)
				elif intent=="economy_preflight": store=Preflight.new(database)
				elif intent=="auction_search": store=AuctionSession.new(database)
				elif intent in ["seller_execute","seller_receipt","seller_snapshot","seller_visit","seller_prepare"]: store=SellerSession.new(database)
				elif intent in ["item_initialize","ground_claim","ground_receipt"]: store=GroundSession.new(database)
				elif intent in ["storage_execute","storage_receipt"]: store=StorageSession.new(database)
				elif intent in ["trade_execute","trade_receipt","trade_recover"]: store=TradeStore.new(database)
				elif intent in ["npc_execute","npc_receipt"]: store=NpcSession.new(database)
				elif intent in ["wallet_snapshot","wallet_batch"]: store=WalletSession.new(database)
				elif intent.is_empty(): store=Items.new(database)
				elif intent in ["session_install","session_inspect","session_revoke","session_ready"]: store=Sessions.new(database)
				else: store=Intents.new(database)
				if intent=="profile_bind": result=store.bind_profile(job.profile_id)
				elif intent=="identity_bind": result=store.bind(job.account_id,job.character)
				elif intent=="economy_preflight": result=store.verify(job.authority_id)
				elif intent=="auction_search": result=store.search(job.session,job.body)
				elif intent=="seller_execute": result=store.execute(job.session,job.action,job.body,job.get("income",0),job.get("token",""),job.get("captures",{}),job.get("participants",[]))
				elif intent=="seller_prepare": result=store.prepare(job.session,job.action,job.body)
				elif intent=="seller_receipt": result=store.receipt(job.session,job.operation_id)
				elif intent=="seller_visit": result=store.visit(job.session,job.shop)
				elif intent=="seller_snapshot": result=store.snapshot(job.session,job.get("include_exchange",false))
				elif intent=="item_initialize": result=store.initialize(job.session)
				elif intent=="ground_claim": result=store.claim(job.session,job.operation_id,job.drop)
				elif intent=="ground_receipt": result=store.receipt(job.session,job.operation_id)
				elif intent=="storage_execute": result=store.execute(job.session,job.operation_id,job.body)
				elif intent=="storage_receipt": result=store.receipt(job.session,job.operation_id)
				elif intent=="trade_execute": result=store.execute(job.operation_id,job.participants)
				elif intent=="trade_recover": result=store.recover(job.operation_id,job.accounts)
				elif intent=="trade_receipt": result=store.receipt(job.session,job.operation_id)
				elif intent=="npc_execute": result=store.execute(job.session,job.npc_kind,job.operation_id,job.body,job.income,job.income_token)
				elif intent=="npc_receipt": result=store.receipt(job.session,job.issuer,job.npc_kind,job.operation_id)
				elif intent=="wallet_snapshot": result=store.snapshot(job.session)
				elif intent=="wallet_batch": result=store.batch(job.session,job.issuer,job.operation_id,job.income,job.cost)
				elif intent=="session_install": result=store.install_verified_grant(job.identity,job.expected_epoch)
				elif intent=="session_inspect": result=store.inspect_grant(job.identity)
				elif intent=="session_revoke": result=store.revoke(job.session)
				elif intent=="session_ready": result=store.finish_recovery(job.session,job.marker)
				elif intent=="session_admit": result=store.admit_session(job.session,job.operation_id,job.action,job.uid,job.revision,job.position)
				elif intent=="session_resume": result=store.resume_session(job.session,job.operation_id)
				elif intent=="session_outcome": result=store.outcome_session(job.session,job.operation_id)
				elif intent=="session_discover": result=store.discover_session(job.session,job.after,job.limit)
				elif intent=="session_pending": result=store.discover_pending_session(job.session,job.after,job.limit)
				elif intent=="session_snapshot": result=store.snapshot_session(job.session,job.get("include_storage",false))
				elif intent=="admit": result=store.admit(job.character,job.operation_id,job.action,job.uid,job.revision,job.position)
				elif intent=="resume": result=store.execute(job.character,job.operation_id)
				elif intent=="outcome": result=store.outcome(job.character,job.operation_id)
				elif intent=="discover": result=store.discover(job.character,job.after,job.limit)
				elif job.lookup:
					result=store.inventory_receipt(job.character,job.operation_id)
				else:
					result=store.inventory_command(job.character,job.action,job.uid,job.revision,job.position,job.operation_id)
				committed=store.committed
				replay=store.receipt_replay
				# Unexpected transaction leakage must not poison another job/session.
				if database.in_transaction():
					database.close()
					result={"ok":false,"error":"storage"} if job.lookup else {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
					committed=false
					replay=false
			var event: Dictionary={"kind":"result","ticket":job.ticket,"character":job.character,"operation_id":job.operation_id,"lookup":job.lookup,"intent":job.get("intent",""),"session":job.get("session",{}),"result":result,"committed":committed,"receipt_replay":replay}
			if started>0: event.metrics={"queued_us":job.queued_us,"started_us":started,"finished_us":Time.get_ticks_usec()}
			_publish(event)
		database.close()
		_connection=""

## Configuration/submit/poll/drain are owned by ONE main-thread caller. Native
## connect and SQL never execute here. Start failure must also be polled to STOPPED.
func start(connection: String, workers: int = 2, capacity_per_worker: int = 2) -> bool:
	if state!=State.STOPPED: return false
	if connection.is_empty() or workers<1 or workers>MAX_WORKERS or capacity_per_worker<1 or capacity_per_worker>MAX_CAPACITY_PER_WORKER: return false
	if not ClassDB.class_exists("GodotSociDatabase"): return false
	state=State.STARTING
	startup_error=""
	_ready_count=0
	_slots=[]
	_capacity=capacity_per_worker
	for index: int in workers:
		var owner:=SessionWorker.new(connection+" application_name=mandate-inventory-executor-"+str(index))
		var thread:=Thread.new()
		var slot: Dictionary={"owner":owner,"thread":thread,"load":0,"joined":false}
		_slots.append(slot)
		if thread.start(owner.run)!=OK:
			slot.joined=true
			startup_error="thread"
			begin_drain()
			return false
	return true

func is_ready() -> bool: return state==State.RUNNING
func is_stopped() -> bool: return state==State.STOPPED
func pending_count() -> int: return _pending.size()

func submit_inventory(character: int, operation_id: String, action: String, uid: String, revision: int, position: int = -1) -> Dictionary:
	if action not in ["move","equip","unequip","activate"] or not ItemInstance.valid_uid(uid) or revision<0: return {"queued":false,"error":"request"}
	return _submit({"character":character,"operation_id":operation_id,"lookup":false,"action":action,"uid":uid,"revision":revision,"position":position})

func submit_receipt(character: int, operation_id: String) -> Dictionary:
	return _submit({"character":character,"operation_id":operation_id,"lookup":true})

func submit_inventory_admission(character: int, operation_id: String, action: String, uid: String, revision: int, position: int = -1) -> Dictionary:
	if not Items.valid_inventory_request(action,uid,revision,position): return {"queued":false,"error":"request"}
	return _submit({"character":character,"operation_id":operation_id,"lookup":false,"intent":"admit","action":action,"uid":uid,"revision":revision,"position":position})

func submit_inventory_resume(character: int, operation_id: String) -> Dictionary:
	return _submit({"character":character,"operation_id":operation_id,"lookup":false,"intent":"resume"})

func submit_inventory_outcome(character: int, operation_id: String) -> Dictionary:
	return _submit({"character":character,"operation_id":operation_id,"lookup":true,"intent":"outcome"})

func submit_inventory_discovery(character: int, after: int = 0, limit: int = 50) -> Dictionary:
	if after<0 or limit<1 or limit>Intents.MAX_PAGE: return {"queued":false,"error":"request"}
	return _submit({"character":character,"operation_id":"","lookup":true,"intent":"discover","after":after,"limit":limit})

## Privileged issuer input only; never a client/World-provided login assertion.
func submit_verified_inventory_grant(identity: Dictionary, expected_epoch: int) -> Dictionary:
	if not Sessions.valid_identity(identity) or expected_epoch<0: return {"queued":false,"error":"request"}
	var safe: Dictionary={"account_id":identity.account_id,"character":identity.character,"session_fingerprint":identity.session_fingerprint}
	return _submit({"character":safe.character,"operation_id":"","lookup":true,"intent":"session_install","control":true,"identity":safe,"expected_epoch":expected_epoch})

func submit_inventory_grant_inspection(identity: Dictionary) -> Dictionary:
	if not Sessions.valid_identity(identity): return {"queued":false,"error":"request"}
	var safe: Dictionary={"account_id":identity.account_id,"character":identity.character,"session_fingerprint":identity.session_fingerprint}
	return _submit({"character":safe.character,"operation_id":"","lookup":true,"intent":"session_inspect","control":true,"identity":safe})

func submit_inventory_revoke(context: Dictionary) -> Dictionary:
	return _session_job(context,"session_revoke","",{})

func submit_inventory_recovery_ready(context: Dictionary, item_state: Dictionary) -> Dictionary:
	if not item_state.get("revision") is int or not item_state.get("authority_id") is String or not item_state.get("account_id") is int or not item_state.get("character_id") is int: return {"queued":false,"error":"request"}
	var marker: Dictionary={"revision":item_state.revision,"authority_id":item_state.authority_id,"account_id":item_state.account_id,"character_id":item_state.character_id}
	return _session_job(context,"session_ready","",{"marker":marker})

func submit_session_inventory(context: Dictionary, operation_id: String, action: String, uid: String, revision: int, position: int) -> Dictionary:
	if not Items.valid_inventory_request(action,uid,revision,position): return {"queued":false,"error":"request"}
	return _session_job(context,"session_admit",operation_id,{"action":action,"uid":uid,"revision":revision,"position":position})

func submit_session_resume(context: Dictionary, operation_id: String) -> Dictionary:
	return _session_job(context,"session_resume",operation_id,{})

func submit_session_outcome(context: Dictionary, operation_id: String) -> Dictionary:
	return _session_job(context,"session_outcome",operation_id,{})

func submit_session_discovery(context: Dictionary, after: int = 0, limit: int = 50) -> Dictionary:
	if after<0 or limit<1 or limit>Intents.MAX_PAGE: return {"queued":false,"error":"request"}
	return _session_job(context,"session_discover","",{"after":after,"limit":limit})

func submit_session_pending_discovery(context: Dictionary, after: int = 0, limit: int = 50) -> Dictionary:
	if after<0 or limit<1 or limit>Intents.MAX_PAGE: return {"queued":false,"error":"request"}
	return _session_job(context,"session_pending","",{"after":after,"limit":limit})

func submit_session_snapshot(context: Dictionary, include_storage: bool = false) -> Dictionary:
	return _session_job(context,"session_snapshot","",{"include_storage":include_storage})

func submit_seller(context: Dictionary, action: String, body: Dictionary, income: int = 0, token: String = "", captures: Dictionary = {}, participants: Array = []) -> Dictionary:
	if action not in SellerSession.ACTIONS or not MarketRequestRules.valid_command(action,body): return {"queued":false,"error":"request"}
	return _session_job(context,"seller_execute",body.command_id,{"action":action,"body":body.duplicate(true),"income":income,"token":token,"captures":captures.duplicate(true),"participants":participants.duplicate()})

func submit_profile_binding(profile: String) -> Dictionary:
	return _submit({"character":1,"operation_id":"profile","lookup":false,"intent":"profile_bind","profile_id":profile,"control":true})

func submit_identity_binding(account: int, character: int) -> Dictionary:
	if account<=0 or character<=0: return {"queued":false,"error":"owner"}
	return _submit({"character":character,"operation_id":"identity","lookup":false,"intent":"identity_bind","account_id":account,"control":true})

func submit_economy_preflight(authority: String) -> Dictionary:
	if not ItemInstance.valid_uid(authority): return {"queued":false,"error":"request"}
	return _submit({"character":1,"operation_id":"","lookup":true,"control":true,"intent":"economy_preflight","session":{},"authority_id":authority})

func submit_auction_search(context: Dictionary, payload: Dictionary) -> Dictionary:
	return _session_job(context,"auction_search","",{"body":payload.duplicate(true)})

func submit_seller_prepare(context: Dictionary, action: String, body: Dictionary) -> Dictionary:
	return _session_job(context,"seller_prepare",body.command_id,{"action":action,"body":body.duplicate(true)})

func submit_seller_visit(context: Dictionary, shop: int) -> Dictionary:
	return _session_job(context,"seller_visit","",{"shop":shop})

func submit_seller_receipt(context: Dictionary, id: String) -> Dictionary:
	return _session_job(context,"seller_receipt",id,{})

func submit_seller_snapshot(context: Dictionary, include_exchange: bool = false) -> Dictionary:
	return _session_job(context,"seller_snapshot","",{"include_exchange":include_exchange})

func submit_item_initialization(context: Dictionary) -> Dictionary:
	return _session_job(context,"item_initialize","",{})

func submit_ground_claim(context: Dictionary, uid: String, drop: Dictionary) -> Dictionary:
	if not ItemInstance.valid_uid(uid): return {"queued":false,"error":"request"}
	return _session_job(context,"ground_claim",uid,{"drop":drop.duplicate(true)})

func submit_ground_receipt(context: Dictionary, uid: String) -> Dictionary:
	if not ItemInstance.valid_uid(uid): return {"queued":false,"error":"request"}
	return _session_job(context,"ground_receipt",uid,{})

func submit_storage(context: Dictionary, operation_id: String, body: Dictionary) -> Dictionary:
	if not StorageSession.valid_body(body): return {"queued":false,"error":"request"}
	return _session_job(context,"storage_execute",operation_id,{"body":body.duplicate(true)})

func submit_storage_receipt(context: Dictionary, operation_id: String) -> Dictionary:
	return _session_job(context,"storage_receipt",operation_id,{})

func submit_wallet_snapshot(context: Dictionary) -> Dictionary:
	return _session_job(context,"wallet_snapshot","",{})

func submit_wallet_batch(context: Dictionary, issuer: int, operation_id: String, income: int, cost: int) -> Dictionary:
	if issuer<=0 or income<0 or income>9000000000000000 or cost<0 or cost>9000000000000000 or (income==0 and cost==0): return {"queued":false,"error":"request"}
	return _session_job(context,"wallet_batch",operation_id,{"issuer":issuer,"income":income,"cost":cost})

func submit_trade(context: Dictionary, id: String, participants: Array) -> Dictionary:
	return _session_job(context,"trade_execute",id,{"participants":participants.duplicate(true)})
func submit_trade_recover(context: Dictionary, id: String, accounts: Array) -> Dictionary:
	return _session_job(context,"trade_recover",id,{"accounts":accounts.duplicate()})
func submit_trade_receipt(context: Dictionary, id: String) -> Dictionary:
	return _session_job(context,"trade_receipt",id,{})

func submit_npc(context: Dictionary, kind: String, operation_id: String, body: Dictionary, income: int, token: String) -> Dictionary:
	if kind not in ["buy","upgrade","sell"] or income<0 or income>9000000000000000 or token.length()!=32: return {"queued":false,"error":"request"}
	return _session_job(context,"npc_execute",operation_id,{"npc_kind":kind,"body":body.duplicate(true),"income":income,"income_token":token})

func submit_npc_receipt(context: Dictionary, issuer: int, kind: String, operation_id: String) -> Dictionary:
	if issuer<=0 or kind not in ["buy","upgrade","sell"]: return {"queued":false,"error":"request"}
	return _session_job(context,"npc_receipt",operation_id,{"issuer":issuer,"npc_kind":kind})

func _session_job(context: Dictionary, mode: String, operation_id: String, fields: Dictionary) -> Dictionary:
	if not Sessions.valid_identity(context) or not context.get("epoch") is int or context.epoch<=0: return {"queued":false,"error":"request"}
	var safe: Dictionary={"account_id":context.account_id,"character":context.character,"session_fingerprint":context.session_fingerprint,"epoch":context.epoch}
	var job: Dictionary={"character":safe.character,"session":safe,"operation_id":operation_id,"lookup":mode not in ["trade_execute","session_admit","session_resume","wallet_batch","npc_execute","storage_execute","item_initialize","ground_claim","seller_execute"],"intent":mode,"control":mode in ["session_ready","session_revoke","session_discover","session_pending","session_snapshot","wallet_snapshot","item_initialize","seller_snapshot","seller_visit","auction_search"]}
	job.merge(fields)
	return _submit(job)

func _submit(job: Dictionary) -> Dictionary:
	if int(job.character)<=0 or (not job.get("control",false) and job.get("intent","")!="discover" and not Commands.valid_id(str(job.operation_id))): return {"queued":false,"error":"request"}
	if state!=State.RUNNING: return {"queued":false,"error":"unavailable"}
	var selected: int=-1
	for index: int in _slots.size():
		if int(_slots[index].load)<_capacity and (selected<0 or int(_slots[index].load)<int(_slots[selected].load)): selected=index
	if selected<0: return {"queued":false,"error":"busy"}
	_next_ticket+=1
	job.ticket=_next_ticket
	if profiling_enabled: job.queued_us=Time.get_ticks_usec()
	_pending[_next_ticket]={"slot":selected,"ticket":_next_ticket,"character":job.character,"operation_id":job.operation_id,"lookup":job.lookup,"intent":job.get("intent",""),"session":job.get("session",{})}
	_slots[selected].load+=1
	_slots[selected].owner.enqueue(job)
	# Volatile local transfer ONLY; never publish this as C2 durable admission.
	return {"queued":true,"ticket":_next_ticket}

## Poll never joins an active thread. Completed-but-unpolled results retain
## capacity, so a slow consumer cannot grow the queues or completion buffers.
func poll() -> Array:
	var completed: Array=[]
	for index: int in _slots.size():
		var slot: Dictionary=_slots[index]
		_consume(slot,completed)
		if not slot.joined and not slot.thread.is_alive():
			slot.thread.wait_to_finish()
			slot.joined=true
			# Drain a completion published between the first read and thread exit.
			_consume(slot,completed)
			if state in [State.STARTING,State.RUNNING]:
				startup_error="worker"
				begin_drain()
			# A dead worker cannot leave local tickets hanging or become a target
			# for new work. Missing results are conservative unknown, never busy.
			for ticket: int in _pending.keys():
				if int(_pending[ticket].slot)!=index: continue
				var lost: Dictionary=_pending[ticket].duplicate(true)
				lost.erase("slot")
				lost.result={"ok":false,"error":"outcome_unknown","outcome_unknown":true}
				lost.committed=false
				lost.receipt_replay=false
				completed.append(lost)
				_pending.erase(ticket)
				slot.load-=1
	if state==State.DRAINING and _pending.is_empty() and _slots.all(func(slot: Dictionary) -> bool: return slot.joined):
		state=State.STOPPED
		_slots=[]
	return completed

func _consume(slot: Dictionary, completed: Array) -> void:
	for event: Dictionary in slot.owner.take_events():
		if event.kind=="ready":
			_ready_count+=1
			if not event.ok:
				startup_error="storage"
				begin_drain()
			elif state==State.STARTING and _ready_count==_slots.size(): state=State.RUNNING
		else:
			_pending.erase(event.ticket)
			slot.load-=1
			if event.has("metrics"):
				var timing: Dictionary=event.metrics
				observation.emit({"intent":event.intent,"queue_us":int(timing.started_us)-int(timing.queued_us),"worker_us":int(timing.finished_us)-int(timing.started_us),"delivery_us":Time.get_ticks_usec()-int(timing.finished_us),"pending":_pending.size(),"ok":event.result.get("ok",false),"committed":event.committed,"replay":event.receipt_replay})
				event.erase("metrics")
			event.erase("kind")
			completed.append(event)

## Finish all buffered work; no timeout/caller disconnect cancels a transaction.
## Owner must keep polling through STOPPED before dropping the executor.
func begin_drain() -> void:
	if state in [State.STOPPED,State.DRAINING]: return
	state=State.DRAINING
	for slot: Dictionary in _slots: slot.owner.drain()
