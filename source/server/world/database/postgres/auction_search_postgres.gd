extends RefCounted
## Domain reader/builder; the optional World runtime uses its builder on a worker
## and projects copied rows on main. No SQLite dispatcher or connection ownership.
const Contract = preload("res://source/server/world/database/auction_search_contract.gd")
var db: Object
var last_db_usec:=0

func _init(database: Object) -> void:
	db=database

static func build_query(payload: Dictionary) -> Dictionary:
	return Contract.build_query(payload,true)

func search(payload: Dictionary) -> Dictionary:
	var built:=build_query(payload)
	if not built.ok: return {"ok":false,"error":built.error}
	# An independent read never inherits or ends the caller's mutable transaction.
	if db.in_transaction(): return {"ok":false,"error":"storage"}
	var started:=Time.get_ticks_usec()
	var result: Dictionary=db.query(built.sql,built.params,int(payload.limit)+1)
	last_db_usec=Time.get_ticks_usec()-started
	if not result.ok or result.truncated: return {"ok":false,"error":"storage"}
	return Contract.project_rows(result.rows,payload)
