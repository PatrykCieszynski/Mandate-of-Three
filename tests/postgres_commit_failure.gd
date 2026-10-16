extends Node
## Minimal native-only reproducer. No Wallet/SQLite/gameplay code participates.
## v0.4.1 Windows currently terminates at commit() with 0xE06D7363. Do not turn
## this into an expected PASS: driver failure containment is a runtime adoption gate.
func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster", "Use the owned PostgreSQL runner")
	var db: Object = ClassDB.instantiate("GodotSociDatabase")
	assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
	assert(db.execute("CREATE TABLE commit_probe(id BIGINT PRIMARY KEY, amount BIGINT NOT NULL);").ok)
	assert(db.execute("INSERT INTO commit_probe VALUES(1,100);").ok)
	assert(db.execute("CREATE FUNCTION reject_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'deferred fixture commit failure'; END; $$;").ok)
	assert(db.execute("CREATE CONSTRAINT TRIGGER fail_commit AFTER UPDATE ON commit_probe DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_commit();").ok)
	assert(db.begin())
	assert(db.execute("UPDATE commit_probe SET amount=90 WHERE id=1;").ok)
	print("POSTGRES_COMMIT_FAILURE_BEFORE_NATIVE_COMMIT")
	var committed: bool = db.commit()
	print("POSTGRES_COMMIT_FAILURE_NATIVE_RETURNED ",committed)
	assert(not committed, "deferred error must return failure instead of terminating Godot")
	if db.in_transaction(): assert(db.rollback())
	assert(db.query("SELECT amount FROM commit_probe WHERE id=1;").rows[0].amount==100)
	db.close()
	print("POSTGRES_COMMIT_FAILURE_OK native failure contained; transaction rolled back")
	get_tree().quit()
