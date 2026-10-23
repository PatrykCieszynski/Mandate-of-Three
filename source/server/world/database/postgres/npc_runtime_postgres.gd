extends RefCounted
## Single-World coordinator for NPC purchases, vendor sales and upgrades. No SQL
## on the simulation thread, no server durable-admission ACK. Client journals
## retain intent; receipts resolve uncertainty before any explicit resubmission.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Content = preload("res://source/server/world/database/postgres/npc_session_postgres.gd")
signal finished(peer: int, kind: String, operation_id: String, result: Dictionary)
signal committed(peer: int, kind: String)
var _wallet: RefCounted
var _inventory: RefCounted
var _executor: RefCounted
var _active: Dictionary={}
var _jobs: Dictionary={}
var _draining:=false
var _vendor_quotes: Dictionary={}
const QUOTE_SECONDS: int=30

func _init(wallet: RefCounted, inventory: RefCounted, executor: RefCounted) -> void:
	_wallet=wallet
	_inventory=inventory
	_executor=executor

## One bounded, server-held quote per bound account. Preview reads the existing
## committed projection only; no SQL, custody change, wallet write or RNG.
func quote(peer: int, npc: String, service: String, basket: Array) -> Dictionary:
	if _draining or not _inventory.mutations_allowed(peer) or not _wallet.ready(peer): return {"ok":false,"error":"recovery_required"}
	var context: Dictionary=_wallet.context_for_peer(peer)
	if context.is_empty() or _active.has(context.account_id): return {"ok":false,"error":"recovery_required"}
	var lines:=VendorResolver.cart(basket)
	var snapshot: Dictionary=_inventory.snapshot_for_peer(peer)
	var plan:=VendorResolver.resolve(lines,snapshot.get("items",[]),VendorRecipes.definitions(),VendorRecipes.pools())
	if not plan.ok: return plan
	var quote: Dictionary={"quote_id":Crypto.new().generate_random_bytes(16).hex_encode(),"lines":lines,"plan":plan,"version":VendorRecipes.version(),"npc":npc,"service":service,"expires_at":int(Time.get_unix_time_from_system())+QUOTE_SECONDS}
	_vendor_quotes[context.account_id]={"context":context.duplicate(true),"quote":quote}
	return {"ok":true,"quote_id":quote.quote_id,"yang":str(plan.yang),"rewards":plan.rewards.duplicate(true),"expires_at":quote.expires_at}

func sell(peer: int, id: String, quote_id: String, npc: String, service: String) -> Dictionary:
	var context: Dictionary=_wallet.context_for_peer(peer)
	var held: Dictionary=_vendor_quotes.get(context.get("account_id",0),{})
	if held.is_empty() or not Sessions.same_context(context,held.context): return {"queued":false,"error":"quote_stale"}
	var quote: Dictionary=held.quote
	if quote.quote_id!=quote_id or quote.npc!=npc or quote.service!=service: return {"queued":false,"error":"quote_stale"}
	return _begin(peer,"sell",id,{"quote":quote},false)

func buy(peer: int, id: String, shop: ShopDefinition, offer: StringName, position: int) -> Dictionary:
	if shop==null or not shop.validation_errors().is_empty(): return {"queued":false,"error":"request"}
	return _begin(peer,"buy",id,{"content":Content.shop_content(shop),"offer":str(offer),"position":position},false)

func upgrade(peer: int, id: String, recipe: UpgradeDefinition, uid: String, revision: int) -> Dictionary:
	if recipe==null or not recipe.validation_errors().is_empty() or not ItemInstance.valid_uid(uid) or revision<0: return {"queued":false,"error":"request"}
	return _begin(peer,"upgrade",id,{"content":Content.upgrade_content(recipe),"uid":uid,"revision":revision},false)

func receipt(peer: int, kind: String, id: String) -> Dictionary:
	var context: Dictionary=_wallet.context_for_peer(peer)
	if context.is_empty(): return {"queued":false,"error":"stale_session"}
	var active: Dictionary=_active.get(context.account_id,{})
	if not active.is_empty():
		if active.id!=id or active.kind!=kind or active.ticket!=0: return {"queued":false,"error":"operation_pending"}
		active.peer=peer
		active.context=context
		if active.stage=="reconcile":
			active.recoveries=0
			_repair(active)
			return {"queued":true}
		active.stage="receipt"
		active.recoveries=0
		_schedule(active)
		return {"queued":true}
	return _begin(peer,kind,id,{},true)

func _begin(peer: int, kind: String, id: String, body: Dictionary, lookup: bool) -> Dictionary:
	if _draining or kind not in ["buy","upgrade","sell"] or not Commands.valid_id(id): return {"queued":false,"error":"request"}
	var context: Dictionary=_wallet.context_for_peer(peer)
	if context.is_empty(): return {"queued":false,"error":"stale_session"}
	if _active.has(context.account_id) or not _inventory.mutations_allowed(peer): return {"queued":false,"error":"recovery_required"}
	var capture: Dictionary=_wallet.reserve_npc(peer,id)
	if capture.is_empty(): return {"queued":false,"error":"recovery_required"}
	if not _inventory.hold_external(peer,id):
		_wallet.finish_npc(context.account_id,id,{"ok":false})
		return {"queued":false,"error":"recovery_required"}
	var active: Dictionary={"account":context.account_id,"peer":peer,"context":context,"issuer":context.character,"id":id,"kind":kind,"body":body.duplicate(true),"income":capture.income,"token":capture.token,"stage":"receipt" if lookup else "execute","ticket":0,"result":{},"changed":false,"recoveries":0,"retry_at":0}
	_active[context.account_id]=active
	# Admission/range was checked in this same World turn. Do not queue a second
	# unbounded wait for capacity that could later execute an expired NPC context.
	_schedule(active)
	return {"queued":true} # Volatile scheduling, never a durable admission receipt.

func _schedule(active: Dictionary) -> void:
	var queued: Dictionary
	if active.stage=="execute": queued=_executor.submit_npc(active.context,active.kind,active.id,active.body,active.income,active.token)
	else: queued=_executor.submit_npc_receipt(active.context,active.issuer,active.kind,active.id)
	if not queued.queued:
		if active.stage=="execute": _settle(active,{"ok":false,"error":queued.error})
		else: _pause(active,str(queued.error))
		return
	active.ticket=queued.ticket
	_jobs[queued.ticket]=active.account

func _pause(active: Dictionary, reason: String) -> void:
	active.stage="paused"
	active.retry_at=Time.get_ticks_msec()+1000
	# Capacity rejection can occur inside submit before the map adapter captures
	# its correlation. Deliver on the next safe turn, qualified to this capture.
	_publish_failure.call_deferred(active.account,active.id,active.token,active.peer,reason)

func _publish_failure(account: int, id: String, token: String, peer: int, reason: String) -> void:
	var active: Dictionary=_active.get(account,{})
	if not active.is_empty() and active.id==id and active.token==token and active.peer==peer and active.stage=="paused" and peer>0:
		finished.emit(peer,active.kind,id,{"ok":false,"error":reason})

func _settle(active: Dictionary, result: Dictionary) -> void:
	_wallet.finish_npc(active.account,active.id,result)
	_inventory.finish_external(active.account,active.id,result.get("item_state",{}))
	active.result=result.duplicate(true)
	active.stage="reconcile"
	active.recoveries=0
	active.retry_at=0

func _repair(active: Dictionary) -> void:
	var repaired: bool=_inventory.repair_external_projection(active.peer)
	repaired=_wallet.retry(active.peer) or repaired
	if repaired:
		active.recoveries+=1
		active.retry_at=Time.get_ticks_msec()+1000

func poll() -> void:
	for account: int in _vendor_quotes.keys():
		var binding: Dictionary=_wallet.binding(account)
		var held: Dictionary=_vendor_quotes[account]
		if binding.is_empty() or not Sessions.same_context(binding.context,held.context) or int(Time.get_unix_time_from_system())>=int(held.quote.expires_at): _vendor_quotes.erase(account)
	for event: Dictionary in _executor.poll():
		if not _jobs.has(event.ticket): continue
		var active: Dictionary=_active.get(_jobs[event.ticket],{})
		_jobs.erase(event.ticket)
		if active.is_empty(): continue
		active.ticket=0
		active.changed=active.changed or (event.get("committed",false) and not event.get("receipt_replay",false))
		var result: Dictionary=event.result
		if not result.get("ok",false) and result.get("error","") in ["storage","outcome_unknown","stale_session","session_required","recovery_required"]:
			_pause(active,str(result.error))
		else: _settle(active,result)
	for account: int in _active.keys():
		var active: Dictionary=_active[account]
		var binding: Dictionary=_wallet.binding(account)
		if not binding.is_empty():
			var replaced: bool=not Sessions.same_context(active.context,binding.context)
			active.peer=binding.peer
			active.context=binding.context
			if replaced and active.stage=="paused": active.retry_at=0;active.recoveries=0
		if active.stage=="reconcile":
			if active.peer==0 or binding.is_empty():
				_active.erase(account) # No retired-session response/fact.
			elif _wallet.settled(active.peer) and _inventory.mutations_allowed(active.peer):
				if active.changed:
					active.changed=false
					committed.emit(active.peer,active.kind)
				# Publication callbacks may replace/detach a session or invalidate
				# a projection. Never finish the retired lane as their consequence.
				var current: Dictionary=_wallet.binding(account)
				if not current.is_empty() and current.peer==active.peer and Sessions.same_context(current.context,active.context) and _wallet.settled(active.peer) and _inventory.mutations_allowed(active.peer):
					_active.erase(account)
					finished.emit(active.peer,active.kind,active.id,active.result)
			elif active.peer>0 and active.recoveries<3 and Time.get_ticks_msec()>=active.retry_at: _repair(active)
		elif active.stage=="paused" and active.peer>0 and active.recoveries<3 and Time.get_ticks_msec()>=active.retry_at:
			active.recoveries+=1
			active.stage="receipt" # Recovery is lookup only, never auto-execution.
			_schedule(active)

func begin_drain() -> void: _draining=true
func drained() -> bool: return _active.is_empty() and _jobs.is_empty()
func shutdown_complete() -> bool:
	if not _draining or not drained(): return false
	_executor.begin_drain()
	return _executor.is_stopped()
