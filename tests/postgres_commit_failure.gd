extends Node
## Minimal native-only reproducer. No Wallet/SQLite/gameplay code participates.
## v0.4.1 Windows terminated at commit() with 0xE06D7363. Keep this regression
## on the installed payload: native failure containment is an adoption gate.
func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster", "Use the owned PostgreSQL runner")
	var db: Object = ClassDB.instantiate("GodotSociDatabase")
	assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
	assert(db.has_method("get_last_error_details"),"Pinned release must expose synchronous structured failures")
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
	var details: Dictionary=db.get_last_error_details()
	assert(details.error_backend=="postgresql" and details.sqlstate=="P0001" and db.in_transaction())
	# PostgreSQL has ended this transaction even though the local flag still
	# owns cleanup. Read error details before any successful SQL clears them.
	assert(db.query("SELECT amount FROM commit_probe WHERE id=1;").rows[0].amount==100)
	assert(db.in_transaction() and db.get_last_error_details().is_empty() and details.sqlstate=="P0001")
	if db.in_transaction(): assert(db.rollback())
	assert(db.query("SELECT amount FROM commit_probe WHERE id=1;").rows[0].amount==100)
	assert(db.execute("DROP TRIGGER fail_commit ON commit_probe;").ok)
	assert(db.begin() and db.execute("UPDATE commit_probe SET amount=80 WHERE id=1;").ok)
	var duplicate: Dictionary=db.execute("INSERT INTO commit_probe VALUES(1,0);")
	assert(not duplicate.ok and duplicate.error_backend=="postgresql" and duplicate.sqlstate=="23505")
	var aborted: Dictionary=db.query("SELECT 1 AS value;")
	assert(not aborted.ok and aborted.sqlstate=="25P02" and db.in_transaction())
	# Existing native bool acknowledges the accepted COMMIT command; PostgreSQL
	# treats it as ROLLBACK here. It is not application outcome proof.
	assert(db.commit() and not db.in_transaction())
	assert(db.query("SELECT amount FROM commit_probe WHERE id=1;").rows[0].amount==100)
	db.close()
	print("POSTGRES_COMMIT_FAILURE_OK native failure contained; transaction rolled back")
	get_tree().quit()
