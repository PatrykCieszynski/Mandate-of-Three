extends RefCounted
## Worker-owned authorized public read. Only copied rows cross to presentation.
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Search = preload("res://source/server/world/database/postgres/auction_search_postgres.gd")
var db: Object
var committed:=false
var receipt_replay:=false
func _init(database: Object) -> void: db=database

func search(context: Dictionary, payload: Dictionary) -> Dictionary:
	var built:=Search.build_query(payload)
	if not built.ok: return {"ok":false,"error":built.error}
	var begun:=Sessions.new(db).begin_context(context,true)
	if not begun.ok: return begun
	var result: Dictionary=db.query(built.sql,built.params,int(payload.limit)+1)
	if not result.ok or result.truncated:
		if not db.rollback(): db.close()
		return {"ok":false,"error":"storage"}
	if not db.commit():
		db.close()
		return {"ok":false,"error":"storage"} # Read only: no economic uncertainty.
	return {"ok":true,"rows":result.rows}
