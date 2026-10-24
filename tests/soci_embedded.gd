extends Node
## Driver replacement risk: preserve transaction/receipt identity and binding bytes
## in the embedded fixtures, with no godot-sqlite native class installed.

func _ready() -> void:
	assert(not ClassDB.class_exists("SQLite"), "retired native driver must not be registered")
	var db := SqliteSoci.new()
	db.path = ":memory:"
	assert(db.open_db(), db.error_message)
	assert(db.query("CREATE TABLE receipt (id INTEGER PRIMARY KEY, uid TEXT UNIQUE, amount INTEGER, note TEXT); CREATE TABLE audit (id INTEGER);"))
	var uid := "0123456789abcdef0123456789abcdef"
	var note := "Zażółć '?' ; -- not SQL /* nor binds */"
	assert(db.query_with_bindings("INSERT INTO receipt VALUES(?, ?, ?, ?);", [1, uid, 9000000000000000, note]))
	var read_ok := db.query_with_bindings("-- ? ; ignored\nSELECT uid, amount, note, '?' AS literal FROM receipt WHERE id=?; /* ? ; */", [1])
	assert(read_ok)
	assert(db.query_result[0].uid == uid and db.query_result[0].amount == 9000000000000000 and db.query_result[0].note == note and db.query_result[0].literal == "?")
	assert(db.query_with_named_bindings("SELECT :id AS first, :id AS repeated, ':other' AS literal;", {"id": 9223372036854775807}))
	assert(db.query_result[0].first == 9223372036854775807 and db.query_result[0].repeated == 9223372036854775807 and db.query_result[0].literal == ":other")
	assert(db.query("BEGIN IMMEDIATE; INSERT INTO audit VALUES(1); ROLLBACK; SELECT COUNT(*) AS n FROM audit;"))
	assert(db.query_result[0].n == 0, "rollback preserves the full batch boundary")
	assert(db.query("CREATE TRIGGER deny_second BEFORE INSERT ON receipt WHEN NEW.id=2 BEGIN SELECT CASE WHEN NEW.amount>0 THEN RAISE(ABORT, 'fixture ; ?') END; END;"))
	assert(db.query("BEGIN IMMEDIATE;"))
	assert(not db.query_with_bindings("INSERT INTO receipt VALUES(?, ?, ?, ?); INSERT INTO audit VALUES(9);", [2, uid + "2", 7, "rejected"]))
	assert(db.query_result.is_empty() and not db.error_message.is_empty())
	assert(db.query("ROLLBACK; SELECT COUNT(*) AS n FROM audit;"))
	assert(db.query_result[0].n == 0, "a failed statement does not run the rest of a batch")
	assert(not db.query_with_bindings("INSERT INTO audit VALUES(?); INSERT INTO audit VALUES(?);", [3]), "validate all bindings before applying anything")
	assert(db.query("SELECT COUNT(*) AS n FROM audit;") and db.query_result[0].n == 0)
	assert(db.query("CREATE TEMP TRIGGER no_semicolon BEFORE INSERT ON audit BEGIN SELECT 1; END"))
	assert(db.query("DROP TRIGGER no_semicolon"))
	assert(db.query("/* control */ BEGIN DEFERRED TRANSACTION; INSERT INTO audit VALUES(3); -- control\nROLLBACK;"))
	assert(db.query("SELECT COUNT(*) AS n FROM audit;") and db.query_result[0].n == 0)
	assert(db.query("BEGIN; INSERT INTO audit VALUES(4); COMMIT; SELECT id FROM audit;"))
	assert(db.query_result[0].id == 4)
	assert(db.close_db())
	assert(not db.query("SELECT 1;"), "closed session fails rather than recreating a database")
	print("SOCI_EMBEDDED_OK real SOCI SQLite, exact bindings/int64, trigger rollback and batch failure")
	get_tree().quit()
