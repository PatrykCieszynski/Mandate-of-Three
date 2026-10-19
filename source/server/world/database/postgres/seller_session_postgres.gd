extends RefCounted
## Worker-owned seller-local and account-claim transactions. No Yang capture,
## buyer settlement, public search or direct Storage writes belong here.
const Seller = preload("res://source/server/world/database/postgres/shop_seller_postgres.gd")
const Claims = preload("res://source/server/world/database/postgres/account_claim_postgres.gd")
const Queries = preload("res://source/server/world/database/postgres/shop_queries_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const ACTIONS: Array[String]=["list","edit","cancel","configure","claim"]
var db: Object
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void: db=database

func execute(context: Dictionary, action: String, payload: Dictionary) -> Dictionary:
	if action not in ACTIONS or not MarketRequestRules.valid_command(action,payload): return {"ok":false,"error":"request"}
	var store: RefCounted=Claims.new(db) if action=="claim" else Seller.new(db)
	store.authorize_session(context)
	var result: Dictionary
	match action:
		"list": result=store.list_item(context.character,payload.command_id,payload.uid,int(payload.revision),int(payload.position),int(payload.price))
		"edit": result=store.edit_offer(context.character,payload.command_id,payload.offer_id,int(payload.revision),int(payload.position),int(payload.price))
		"cancel": result=store.cancel_offer(context.character,payload.command_id,payload.offer_id,int(payload.revision))
		"configure": result=store.configure(context.character,payload.command_id,int(payload.revision),payload.name,payload.status)
		"claim": result=store.claim_item(context.character,payload.command_id,payload.uid,int(payload.revision))
	committed=store.committed
	receipt_replay=store.receipt_replay
	return result

func snapshot(context: Dictionary) -> Dictionary:
	var queries:=Queries.new(db)
	queries.authorize_session(context)
	var result:=queries.mine(context.character)
	if result.get("ok",false): result.seller_runtime=true
	return result

func receipt(context: Dictionary, id: String) -> Dictionary:
	if not Commands.valid_id(id): return {"ok":false,"error":"request"}
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND command_id=:id AND kind IN ('list','edit','cancel','configure','claim');",{"account":context.account_id,"id":id})
	if not found.ok:
		if not db.rollback(): db.close()
		return {"ok":false,"error":"storage"}
	var result: Dictionary={"ok":false,"error":"unknown_command"} if found.rows.is_empty() else Commands.decode(str(found.rows[0].result_json))
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	receipt_replay=result.get("ok",false)
	return result
