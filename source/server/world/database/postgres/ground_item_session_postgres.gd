extends RefCounted
## Worker-only starter/ground claim adapter. Ground contents come from the
## authoritative World, never an RPC item DTO. Existing durable markers own retry.
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
var db: Object
var committed:=false
var receipt_replay:=false

func _init(database: Object) -> void: db=database

func initialize(context: Dictionary) -> Dictionary:
	var store:=Items.new(db)
	store.authorize_session(context)
	var result:=store.initialize_character(context.character)
	committed=store.committed
	return result

func claim(context: Dictionary, uid: String, drop: Dictionary) -> Dictionary:
	var item:=GroundLootSystem.prepare_claim_item(uid,int(context.character),drop)
	if item==null: return {"ok":false,"error":"request"}
	var store:=Items.new(db)
	store.authorize_session(context)
	var result:=store.claim_ground_item(context.character,uid,item)
	committed=store.committed
	return result

func receipt(context: Dictionary, uid: String) -> Dictionary:
	if not ItemInstance.valid_uid(uid): return {"ok":false,"error":"request"}
	var begun:=Sessions.new(db).begin_context(context)
	if not begun.ok: return begun
	var found: Dictionary=db.query("SELECT c.account_id FROM economy.ground_item_claims g JOIN economy.characters c ON c.character_id=g.owner_character_id WHERE g.drop_uid=:uid;",{"uid":uid})
	if not found.ok:
		if not db.rollback(): db.close()
		return {"ok":false,"error":"storage"}
	var result: Dictionary={"ok":false,"error":"unknown_command"}
	if not found.rows.is_empty():
		result={"ok":true,"uid":uid} if int(found.rows[0].account_id)==int(context.account_id) else {"ok":false,"error":"claimed"}
	if not db.commit():
		db.close()
		return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}
	receipt_replay=result.get("ok",false)
	return result
