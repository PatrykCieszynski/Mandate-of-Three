class_name SqliteSoci
extends RefCounted
## Embedded fixture/reference SQL through the same pinned godot-soci dependency as PG.
## Not a second production authority or a backend-selection/fallback mechanism.
## Retains the small query surface used by existing reference stores and network fixtures.

var path: String
var foreign_keys: bool = true
var query_result: Array[Dictionary] = []
var error_message: String = ""
var _driver: Object

func open_db() -> bool:
	if _driver != null: return _driver.is_open()
	if not ClassDB.class_exists("GodotSociDatabase"):
		error_message = "Install pinned godot-soci with tools/soci/setup.py"
		return false
	var physical := path if path == ":memory:" else ProjectSettings.globalize_path(path)
	# SOCI's connection parser has no escape syntax for an embedded quote.
	if physical.is_empty() or "'" in physical or "\n" in physical or "\r" in physical:
		error_message = "Invalid embedded database path"
		return false
	_driver = ClassDB.instantiate("GodotSociDatabase")
	if not _driver.open("sqlite3", "dbname='%s' timeout=1000" % physical.replace("\\", "/")):
		error_message = _driver.get_last_error()
		_driver = null
		return false
	return query("PRAGMA foreign_keys=" + ("ON" if foreign_keys else "OFF"))

func close_db() -> bool:
	if _driver != null:
		_driver.close()
		_driver = null
	query_result.clear()
	return true

func query(sql: String) -> bool:
	return query_with_bindings(sql, [])

func query_with_bindings(sql: String, bindings: Array) -> bool:
	return _run_query(sql, bindings, {})

func query_with_named_bindings(sql: String, bindings: Dictionary) -> bool:
	return _run_query(sql, [], bindings)

func _run_query(sql: String, bindings: Array, named: Dictionary) -> bool:
	query_result.clear()
	error_message = ""
	if _driver == null:
		error_message = "Database is closed"
		return false
	var statements := _prepare(sql, bindings, named)
	if not error_message.is_empty(): return false
	for statement: Dictionary in statements:
		var text: String = statement.sql.strip_edges()
		var control: String = statement.control
		var ok := true
		match control:
			"BEGIN", "BEGIN TRANSACTION", "BEGIN DEFERRED", "BEGIN DEFERRED TRANSACTION": ok = _driver.begin()
			"BEGIN IMMEDIATE", "BEGIN IMMEDIATE TRANSACTION": ok = _driver.begin_immediate()
			"COMMIT", "END", "END TRANSACTION": ok = _driver.commit()
			"ROLLBACK", "ROLLBACK TRANSACTION": ok = _driver.rollback()
			_:
				var result: Dictionary
				if statement.rows:
					result = _driver.query(text, statement.params, 100000)
				else:
					result = _driver.execute(text, statement.params)
				ok = result.get("ok", false) and not result.get("truncated", false)
				query_result.clear()
				if ok: query_result.assign(result.get("rows", []))
				else: error_message = str(result.get("error", "")) if not result.get("truncated", false) else "Embedded query result truncated"
		if not ok:
			if error_message.is_empty(): error_message = _driver.get_last_error()
			query_result.clear()
			return false
	return true

## Translate positional reference SQL to named SOCI binds, and split batches before
## execution (SOCI prepares only the first SQLite statement). Quotes/comments and
## trigger BEGIN/CASE/END bodies must not introduce binds or statement boundaries.
func _prepare(sql: String, bindings: Array, named: Dictionary) -> Array[Dictionary]:
	var used: Dictionary = {}
	var statements: Array[Dictionary] = []
	var text := ""
	var params: Dictionary = {}
	var tokens: PackedStringArray = []
	var quote := ""
	var comment := ""
	var token := ""
	var depth := 0
	var trigger := false
	var index := 0
	var bind := 0
	while index < sql.length():
		var char := sql[index]
		var next := sql[index + 1] if index + 1 < sql.length() else ""
		if not comment.is_empty():
			text += char
			if comment == "--" and char == "\n": comment = ""
			elif comment == "/*" and char == "*" and next == "/":
				text += next; index += 1; comment = ""
		elif not quote.is_empty():
			text += char
			if char == quote:
				if next == quote and quote != "]": text += next; index += 1
				else: quote = ""
		else:
			if char.is_valid_identifier() or char.is_valid_int():
				token += char; text += char; index += 1; continue
			if not token.is_empty():
				var upper := token.to_upper()
				tokens.append(upper)
				if upper == "TRIGGER" and tokens[0] == "CREATE": trigger = true
				if trigger:
					if upper in ["BEGIN", "CASE"]: depth += 1
					elif upper == "END": depth -= 1
				token = ""
			if (char == "-" and next == "-") or (char == "/" and next == "*"):
				comment = char + next; text += comment; index += 1
			elif char in ["'", "\"", "`", "["]:
				quote = "]" if char == "[" else char; text += char
			elif char == ":" and next.is_valid_identifier():
				var end := index + 1
				while end < sql.length() and (sql[end].is_valid_identifier() or sql[end].is_valid_int()): end += 1
				var key := sql.substr(index + 1, end - index - 1)
				if not named.has(key):
					error_message = "Missing named SQL binding: " + key; return []
				text += ":" + key; params[key] = named[key]; used[key] = true
				index = end - 1
			elif char == "?":
				if bind >= bindings.size():
					error_message = "Missing positional SQL binding"; return []
				var key := "soci_bind_%d" % bind
				text += ":" + key; params[key] = bindings[bind]; bind += 1
			elif char == ";" and (not trigger or depth == 0):
				if not tokens.is_empty(): statements.append(_statement(text, params, tokens))
				text = ""; params = {}; tokens = []; trigger = false; depth = 0
			else: text += char
		index += 1
	if not token.is_empty():
		tokens.append(token.to_upper())
		if trigger and token.to_upper() == "END": depth -= 1
	if not quote.is_empty() or comment == "/*" or depth != 0:
		error_message = "Unterminated SQL quote/comment/trigger"; return []
	if bind != bindings.size() or used.size() != named.size():
		error_message = "Unused SQL binding"; return []
	if not tokens.is_empty(): statements.append(_statement(text, params, tokens))
	return statements

func _statement(sql: String, params: Dictionary, tokens: PackedStringArray) -> Dictionary:
	return {"sql":sql,"params":params,"control":" ".join(tokens),"rows":tokens[0] in ["SELECT", "WITH", "PRAGMA", "EXPLAIN", "VALUES"] or "RETURNING" in tokens}
