extends RefCounted
## Worker-owned Marketplace transactions and receipts. Captured Yang is copied
## from the server wallet owner; no public search or direct Storage writes here.
const Seller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
const Claims = preload("res://source/server/world/database/postgres/account_claim_postgres.gd")
const Queries = preload("res://source/server/world/database/postgres/shop_queries_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Settlement = preload("res://source/server/world/database/postgres/shop_settlement_postgres.gd")
const Ledger = preload("res://source/server/world/database/postgres/exchange_ledger_postgres.gd")
const Orders = preload("res://source/server/world/database/postgres/exchange_orders_postgres.gd")
const ACTIONS: Array[String]=["list","edit","cancel","configure","claim","buy","claim_revenue","deposit","withdraw","order","cancel_order"]
var db: Object
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void: db=database

func execute(context: Dictionary, action: String, payload: Dictionary, income: int = 0, token: String = "", captures: Dictionary = {}, participants: Array = []) -> Dictionary:
	if action not in ACTIONS or not MarketRequestRules.valid_command(action,payload): return {"ok":false,"error":"request"}
	var store: RefCounted
	if action in ["order","cancel_order"]:
		store=Orders.new(db)
		store.authorize_session(context,captures,participants)
	elif action in ["deposit","withdraw"]:
		store=Ledger.new(db)
		store.authorize_session(context)
	elif action in ["buy","claim_revenue"]:
		store=Settlement.new(db)
		store.authorize_session(context,token)
	else:
		store=Claims.new(db) if action=="claim" else Seller.new(db)
		store.authorize_session(context)
	var result: Dictionary
	match action:
		"order": result=store.place_order(context.character,payload,_pending(captures))
		"cancel_order": result=store.cancel_order(context.character,payload.command_id,payload.order_id,int(payload.revision),_pending(captures))
		"deposit": result=store.deposit(context.character,payload.command_id,payload.uid,int(payload.revision),int(payload.amount),payload.source)
		"withdraw": result=store.withdraw(context.character,payload.command_id,payload.asset_id,int(payload.amount),payload.destination)
		"buy": result=store.purchase(context.character,payload.command_id,int(payload.shop_id),payload.offer_id,int(payload.revision),int(payload.price),{context.account_id:income})
		"claim_revenue": result=store.claim_revenue(context.character,payload.command_id,income)
		"list": result=store.list_item(context.character,payload.command_id,payload.uid,int(payload.revision),int(payload.position),int(payload.price))
		"edit": result=store.edit_offer(context.character,payload.command_id,payload.offer_id,int(payload.revision),int(payload.position),int(payload.price))
		"cancel": result=store.cancel_offer(context.character,payload.command_id,payload.offer_id,int(payload.revision))
		"configure": result=store.configure(context.character,payload.command_id,int(payload.revision),payload.name,payload.status)
		"claim": result=store.claim_item(context.character,payload.command_id,payload.uid,int(payload.revision))
	committed=store.committed
	receipt_replay=store.receipt_replay
	return result

func snapshot(context: Dictionary, include_exchange: bool = false) -> Dictionary:
	var queries:=Queries.new(db)
	queries.authorize_session(context)
	var result:=queries.mine(context.character,include_exchange)
	if result.get("ok",false): result.seller_runtime=true
	return result

func receipt(context: Dictionary, id: String) -> Dictionary:
	if not Commands.valid_id(id): return {"ok":false,"error":"request"}
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND command_id=:id AND kind IN ('list','edit','cancel','configure','claim','buy','claim_revenue','exchange.deposit','exchange.withdraw','exchange.order','exchange.cancel');",{"account":context.account_id,"id":id})
	if not found.ok:
		if not db.rollback(): db.close()
		return {"ok":false,"error":"storage"}
	var result: Dictionary={"ok":false,"error":"unknown_command"} if found.rows.is_empty() else Commands.decode(str(found.rows[0].result_json))
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	receipt_replay=result.get("ok",false)
	return result

func visit(context: Dictionary, shop: int) -> Dictionary:
	# Grant validation and public projection share one worker-owned transaction.
	return Queries.new(db).visit_authorized(context,shop)

static func _pending(captures: Dictionary) -> Dictionary:
	var pending: Dictionary={}
	for account: int in captures: pending[account]=int(captures[account].get("income",0))
	return pending

## Discovery only; execution reselects under the pair lock and refuses a changed set.
func prepare(context: Dictionary, action: String, body: Dictionary) -> Dictionary:
	if action not in ["order","cancel_order"] or not MarketRequestRules.valid_command(action,body): return {"ok":false,"error":"request"}
	var begun:=Sessions.new(db).begin_context(context,true)
	if not begun.ok: return begun
	var participants: Array[int]=[int(context.account_id)]
	if action=="order":
		var base: String=body.want_asset if body.have_asset=="yang" else body.have_asset
		var side: String="buy" if body.have_asset=="yang" else "sell"
		var found: Dictionary=db.query("SELECT DISTINCT account_id FROM economy.exchange_orders WHERE base_asset=:base AND side<>:side AND status='active';",{"base":base,"side":side},Orders.MAX_PAIR_ORDERS+1)
		if not found.ok or found.truncated:
			db.rollback()
			return {"ok":false,"error":"storage"}
		for row: Dictionary in found.rows:
			if int(row.account_id) not in participants: participants.append(int(row.account_id))
	participants.sort()
	if participants.size()>64:
		db.rollback()
		return {"ok":false,"error":"participant_busy"}
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown"}
	return {"ok":true,"participants":participants}
