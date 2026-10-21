class_name ChatStorePostgres
extends RefCounted

var db: Object

func _init(_db: Object) -> void:
	db = _db

func ensure_conversation(conversation_id: String, type: String, meta_json: String = "{}") -> void:
	_query(
		"INSERT INTO conversations(conversation_id, type, meta_json) VALUES(:p0, :p1, :p2) ON CONFLICT DO NOTHING;",
		[conversation_id, type, meta_json]
	)

func next_msg_id(conversation_id: String) -> int:
	if not _query(
		"UPDATE conversations SET next_msg_id=next_msg_id+1 WHERE conversation_id=:p0 RETURNING next_msg_id;",
		[conversation_id]
	) or _rows.is_empty(): return -1
	var row: Dictionary = _rows[0]
	return int(row.next_msg_id)

func insert_message(
	conversation_id: String,
	time_ms: int,
	sender_id: int,
	sender_name: String,
	text: String
) -> Dictionary:
	var msg_id := next_msg_id(conversation_id)
	if msg_id<0: return {}
	if not _query(
		"INSERT INTO messages(conversation_id, msg_id, time_ms, sender_id, sender_name, text) "
		+ "VALUES(:p0, :p1, :p2, :p3, :p4, :p5);",
		[conversation_id, msg_id, time_ms, sender_id, sender_name, text]
	): return {}
	return {
		"conversation_id": conversation_id,
		"msg_id": msg_id,
		"time_ms": time_ms,
		"sender_id": sender_id,
		"sender_name": sender_name,
		"text": text
	}


func fetch_last(conversation_id: String, limit: int = 50) -> Array:
	_query(
		"SELECT conversation_id, msg_id, time_ms, sender_id, sender_name, text "
		+ "FROM messages WHERE conversation_id=:p0 "
		+ "ORDER BY msg_id DESC LIMIT :p1;",
		[conversation_id, limit]
	)
	var rows: Array = _rows.duplicate()
	rows.reverse()
	return rows


func moderation_last_24h(sender_id: int, now_ms: int) -> Array:
	var since := now_ms - 24 * 60 * 60 * 1000
	_query(
		"SELECT conversation_id, msg_id, time_ms, sender_id, text "
		+ "FROM messages WHERE sender_id=:p0 AND time_ms>=:p1 "
		+ "ORDER BY time_ms DESC;",
		[sender_id, since]
	)
	return _rows


# This store's native PostgreSQL queries only; no SQL dialect translation.
var _rows: Array=[]
func _query(sql: String, values: Array=[]) -> bool:
	var bindings: Dictionary={}
	for index: int in values.size(): bindings["p"+str(index)]=values[index]
	var returns_rows: bool=sql.begins_with("SELECT ") or sql.contains(" RETURNING ")
	var result: Dictionary=db.query(sql,bindings,100000) if returns_rows else db.execute(sql,bindings)
	_rows=result.get("rows",[]) if result.ok else []
	return result.ok and not result.get("truncated",false)
