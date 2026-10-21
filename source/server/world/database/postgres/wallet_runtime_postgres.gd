extends RefCounted
## Single-World RAM wallet owner. Polls its own instance of the existing bounded
## executor; never share a result consumer with Inventory. No SQL on this thread.
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Versions = preload("res://source/common/gameplay/items/domain/wallet_state_version.gd")
const SAVE_SECONDS: float=30.0
const MAX_ACCOUNTS: int=64
signal changed(peer_id: int)
signal failed(account_id: int, reason: String)
signal spend_finished(peer_id: int, operation_id: String, result: Dictionary)
var _world: WorldServer
var _executor: RefCounted
var _accounts: Dictionary={}
var _exchange_holds: Dictionary={}
var _jobs: Dictionary={}
var _elapsed: float=0.0
var _draining:=false

func _init(world: WorldServer, executor: RefCounted) -> void:
	_world=world
	_executor=executor

func attach(peer: int, context: Dictionary) -> bool:
	if _draining or not Sessions.valid_identity(context) or not context.get("epoch") is int or context.epoch<=0: return false
	if _world.session_ticket_fingerprint(peer,context.character)!=context.session_fingerprint: return false
	if not _accounts.has(context.account_id):
		if _accounts.size()>=MAX_ACCOUNTS: return false
		_accounts[context.account_id]={"peer":peer,"context":context.duplicate(true),"state":{},"pending":0,"work":{},"external":{},"ticket":0,"stage":"load","flush":false,"force":false,"error":"","notify":{}}
	else:
		var account: Dictionary=_accounts[context.account_id]
		if account.peer==peer and Sessions.same_context(account.context,context): return true
		# Keep dirty income, the original batch identity and in-flight result. A
		# replacement cannot load an older DB balance over uncheckpointed RAM.
		account.peer=peer
		account.context=context.duplicate(true)
		account.force=true
		account.flush=true
		if account.ticket==0: account.stage="apply" if not account.work.is_empty() else "load"
	return true

func _for_peer(peer: int) -> Dictionary:
	for account: Dictionary in _accounts.values():
		if account.peer==peer and _world.session_ticket_fingerprint(peer,account.context.character)==account.context.session_fingerprint: return account
	return {}

func ready(peer: int) -> bool:
	var account:=_for_peer(peer)
	return not _draining and not account.is_empty() and not _exchange_holds.has(account.context.account_id) and account.external.is_empty() and not account.force and not account.state.is_empty() and account.stage in ["ready","apply"] and (account.work.is_empty() or account.work.cost==0)

func settled(peer: int) -> bool:
	var account:=_for_peer(peer)
	return not account.is_empty() and not _exchange_holds.has(account.context.account_id) and account.stage=="ready" and not account.state.is_empty() and account.external.is_empty() and account.work.is_empty() and not account.force

func snapshot(peer: int) -> Dictionary:
	var account:=_for_peer(peer)
	if account.is_empty() or _exchange_holds.has(account.context.account_id) or not account.external.is_empty() or account.force or account.state.is_empty() or account.stage not in ["ready","apply"] or (not account.work.is_empty() and account.work.cost>0): return {}
	return {"balance":int(account.state.balance)+int(account.pending),"wallet_state":{"authority_id":account.state.authority_id,"account_id":account.context.account_id,"revision":account.state.revision}}

func add_income(peer: int, amount: int) -> bool:
	if not ready(peer) or amount<=0: return false
	var account:=_for_peer(peer)
	if amount>Wallet.MAX_YANG-int(account.state.balance)-int(account.pending): return false
	account.pending+=amount
	changed.emit(peer)
	return true

func _capture(account: Dictionary, cost: int = 0, operation_id: String = "") -> void:
	if operation_id.is_empty(): operation_id="wallet:"+Crypto.new().generate_random_bytes(16).hex_encode()
	account.work={"id":operation_id,"issuer":int(account.context.character),"income":int(account.pending),"cost":cost}
	account.stage="apply"
	account.flush=account.force or account.peer==0 or _draining

## Server-only fixed-cost fixture entry, not a client-controlled debit API.
func test_spend(peer: int) -> Dictionary:
	if not ready(peer): return {"queued":false,"error":"recovery_required"}
	var account:=_for_peer(peer)
	if not account.work.is_empty(): return {"queued":false,"error":"operation_pending"}
	if int(account.state.balance)+int(account.pending)-int(account.state.reserved_yang)<50: return {"queued":false,"error":"funds"}
	_capture(account,50)
	return {"queued":true,"operation_id":account.work.id}

func binding(account_id: int) -> Dictionary:
	var account: Dictionary=_accounts.get(account_id,{})
	if account.is_empty(): return {}
	return {"peer":account.peer if not _for_peer(account.peer).is_empty() else 0,"context":account.context.duplicate(true)}

func context_for_peer(peer: int) -> Dictionary:
	var account:=_for_peer(peer)
	return {} if account.is_empty() else account.context.duplicate(true)

func reserve_npc(peer: int, operation_id: String) -> Dictionary:
	if not ready(peer): return {}
	var account:=_for_peer(peer)
	if not account.work.is_empty() or account.ticket!=0: return {}
	account.external={"id":operation_id,"income":int(account.pending),"token":Crypto.new().generate_random_bytes(16).hex_encode()}
	return {"context":account.context.duplicate(true),"income":account.external.income,"token":account.external.token}

## Pair settlement fences account admission even if no wallet is currently loaded.
## A login while native SQL runs may hydrate, but cannot expose/spend stale state.
func reserve_exchange(account_id: int, operation_id: String) -> Dictionary:
	if _draining or account_id<=0 or _exchange_holds.has(account_id): return {}
	var capture: Dictionary={"income":0,"token":"","context":{}}
	var account: Dictionary=_accounts.get(account_id,{})
	if not account.is_empty():
		if account.peer<=0:
			if account.pending!=0 or not account.work.is_empty() or not account.external.is_empty() or account.ticket!=0: return {}
		else:
			capture=reserve_npc(account.peer,operation_id)
			if capture.is_empty(): return {}
	_exchange_holds[account_id]=operation_id
	return capture

func finish_exchange(account_id: int, operation_id: String, result: Dictionary) -> void:
	if _exchange_holds.get(account_id,"")!=operation_id: return
	_exchange_holds.erase(account_id)
	var tokens: Dictionary=result.get("income_tokens",{})
	finish_npc(account_id,operation_id,{"ok":result.get("ok",false),"income_token":tokens.get(str(account_id),"")})
	var account: Dictionary=_accounts.get(account_id,{})
	if not account.is_empty() and account.external.is_empty() and account.work.is_empty():
		account.stage="ready" if account.peer==0 and account.pending==0 else "load" # Includes login during settlement.

func exchange_held(account_id: int) -> bool: return _exchange_holds.has(account_id)

func finish_npc(account_id: int, operation_id: String, result: Dictionary) -> void:
	var account: Dictionary=_accounts.get(account_id,{})
	if account.is_empty() or account.external.get("id","")!=operation_id: return
	# An old receipt may belong to a previous RAM owner. Only a matching capture
	# token consumes this prefix; new income never disappears during receipt replay.
	if result.get("ok",false) and result.get("income_token","")==account.external.token:
		account.pending-=int(account.external.income)
	account.external={}
	if account.peer==0 and account.pending==0:
		account.stage="ready" # Durable completion needs no revoked-session read.
	else: account.stage="load"

## A failed/unknown attempt is paused, never discarded or given a new identity.
func retry(peer: int) -> bool:
	var account:=_for_peer(peer)
	if account.is_empty() or account.ticket!=0 or account.stage!="paused": return false
	account.stage="apply" if not account.work.is_empty() else "load"
	return true

func detach(peer: int) -> void:
	for account: Dictionary in _accounts.values():
		if account.peer!=peer: continue
		account.peer=0
		account.flush=true
		account.force=true
		# Dirty/offline accounts remain owned until an acknowledged checkpoint.

## Request a barrier before local transfer/logout; caller polls, never waits in
## SQL. Dirty/in-flight/paused state must prevent a handoff or clean shutdown.
func checkpoint(peer: int) -> bool:
	var account:=_for_peer(peer)
	if account.is_empty(): return false
	account.flush=true
	account.force=true
	return account.stage=="ready" and account.pending==0 and account.work.is_empty() and account.ticket==0

func begin_drain() -> void:
	_draining=true
	checkpoint_all()

func checkpoint_all() -> void:
	for account: Dictionary in _accounts.values():
		account.flush=true
		account.force=true

func drained() -> bool:
	return _exchange_holds.is_empty() and _jobs.is_empty() and _accounts.values().all(func(account: Dictionary) -> bool: return account.stage=="ready" and account.pending==0 and account.work.is_empty() and account.external.is_empty())

func shutdown_complete() -> bool:
	if not _draining or not drained(): return false
	_executor.begin_drain()
	return _executor.is_stopped()

func poll(delta: float = 0.0) -> void:
	_elapsed+=delta
	var periodic: bool=_elapsed>=SAVE_SECONDS
	if periodic: _elapsed=fmod(_elapsed,SAVE_SECONDS)
	for event: Dictionary in _executor.poll():
		if not _jobs.has(event.ticket): continue
		var job: Dictionary=_jobs[event.ticket]
		_jobs.erase(event.ticket)
		var account: Dictionary=_accounts[job.account]
		account.ticket=0
		var result: Dictionary=event.result
		if not result.get("ok",false):
			if job.mode=="apply" and job.cost>0 and result.get("error","")=="funds" and not result.get("outcome_unknown",false):
				# Definite transactional rejection: pending income was rolled back,
				# so retain it and refresh before publishing the rejected spend.
				account.work={}
				account.stage="load"
				account.notify={"peer":account.peer,"context":job.context,"id":job.id,"result":{"ok":false,"error":"funds"}}
				continue
			# A changed session can safely retry the same captured operation. No
			# response is applied to a retired peer. Storage/unknown are retried on
			# the next checkpoint (or explicitly); session failures await reattach.
			if result.get("error","")=="stale_session" and not Sessions.same_context(job.context,account.context):
				account.stage="apply" if not account.work.is_empty() else "load"
			else:
				account.stage="paused"
				account.error=str(result.get("error","storage"))
				failed.emit(job.account,account.error)
				if job.cost>0 and account.peer>0 and Sessions.same_context(job.context,account.context) and not _for_peer(account.peer).is_empty(): spend_finished.emit(account.peer,job.id,{"ok":false,"error":"wallet_pending","pending":true})
			continue
		if job.mode=="apply":
			account.pending-=int(account.work.income)
			account.work={}
			# Receipt replay may describe an old wallet revision. Refresh current
			# state after every result rather than treating that receipt as a cache.
			account.stage="load"
			if job.cost>0: account.notify={"peer":account.peer,"context":job.context,"id":job.id,"result":{"ok":true,"spent":job.cost}}
		else:
			if not Sessions.same_context(job.context,account.context):
				account.stage="load"
				continue
			var state: Dictionary=result.wallet_state
			if not Versions.valid(state) or state.account_id!=job.account or (not account.state.is_empty() and (state.authority_id!=account.state.authority_id or state.revision<account.state.revision)) or int(state.balance)>Wallet.MAX_YANG-int(account.pending):
				account.stage="paused"
				failed.emit(job.account,"wallet_reconciliation")
				continue
			account.state=state.duplicate(true)
			account.stage="ready"
			if account.peer>0 and not _for_peer(account.peer).is_empty(): changed.emit(account.peer)
			var notice: Dictionary=account.notify
			account.notify={}
			if not notice.is_empty() and notice.peer==account.peer and Sessions.same_context(notice.context,account.context) and not _for_peer(account.peer).is_empty(): spend_finished.emit(account.peer,notice.id,notice.result)
	for key: int in _accounts.keys():
		var account: Dictionary=_accounts[key]
		if _exchange_holds.has(key) or not account.external.is_empty(): continue
		if periodic:
			account.flush=true
			if account.stage=="paused" and account.error in ["storage","outcome_unknown"]:
				account.stage="apply" if not account.work.is_empty() else "load"
		if account.ticket!=0 or account.stage=="paused": continue
		if account.stage=="ready" and account.flush:
			if account.pending>0: _capture(account)
			else:
				account.flush=false
				account.force=false
		if account.stage not in ["load","apply"]:
			if account.peer==0 and account.pending==0 and account.work.is_empty(): _accounts.erase(key)
			continue
		var mode: String=account.stage
		var queued: Dictionary
		if mode=="load": queued=_executor.submit_wallet_snapshot(account.context)
		else: queued=_executor.submit_wallet_batch(account.context,account.work.issuer,account.work.id,account.work.income,account.work.cost)
		if not queued.queued: continue # Bounded backpressure, keep captured work.
		account.ticket=queued.ticket
		_jobs[queued.ticket]={"account":key,"context":account.context.duplicate(true),"mode":mode,"id":account.work.get("id",""),"cost":account.work.get("cost",0)}
