extends Node
## Real SQLite proves checkpoint batching, rollback, narrow writes and the
## accepted crash window. No persistent kill events or economy batching.
var failed: bool = false

class CountingWorldStore extends WorldStoreSqlite:
	var batches: int = 0
	var rows: int = 0
	func save_progression(players: Array[PlayerResource]) -> bool:
		batches += 1
		rows += players.size()
		return super.save_progression(players)

func check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("CHECKPOINT_FAILED: " + message)
		get_tree().quit(1)

func _ready() -> void:
	var db := SQLite.new()
	db.path = "res://.godot/verification/checkpoint-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	check(db.open_db(), "open isolated SQLite")
	WorldSchema.ensure_schema(db)
	var store := CountingWorldStore.new(db)
	var first: int = store.create_player_character("checkpoint_a", {"name": "A", "skin": 1})
	var second: int = store.create_player_character("checkpoint_b", {"name": "B", "skin": 1})
	var clean: int = store.create_player_character("checkpoint_c", {"name": "C", "skin": 1})
	# Exercise the upgrade from the previously published schema, including removal
	# of historical receipts, without losing existing character/item state.
	check(db.query("CREATE TABLE kill_xp_rewards(kill_uid TEXT PRIMARY KEY,owner_character_id INTEGER,amount INTEGER);"), "old receipt fixture")
	check(db.query("INSERT INTO kill_xp_rewards VALUES('historical',1,20);"), "old receipt row")
	check(db.query("UPDATE meta SET value='12' WHERE key='schema_version';"), "old schema marker")
	WorldSchema.ensure_schema(db)
	check(db.query("SELECT name FROM sqlite_master WHERE name='kill_xp_rewards';") and db.query_result.is_empty(), "v13 removes obsolete receipt history")
	var persistence := WorldDatabase.new()
	persistence.db = db
	persistence.store = store
	add_child(persistence)
	var a: PlayerResource = store.get_player(first)
	var b: PlayerResource = store.get_player(second)
	var c: PlayerResource = store.get_player(clean)
	var profile: String = a.profile_status
	# Forbid unrelated writes: an XP checkpoint cannot invoke full serialization.
	check(db.query("CREATE TEMP TRIGGER reject_full_save BEFORE INSERT ON players BEGIN SELECT RAISE(ABORT,'checkpoint tried full serialization'); END;"), "reject full serializer")
	check(db.query("CREATE TEMP TRIGGER reject_profile_save BEFORE UPDATE OF profile_status,inventory_json,quests_json ON players BEGIN SELECT RAISE(ABORT,'checkpoint touched unrelated columns'); END;"), "reject unrelated columns")
	for i: int in 4: a.add_experience(20)
	b.add_experience(40)
	persistence.mark_progression_dirty(a)
	persistence.mark_progression_dirty(b)
	check(store.batches == 0 and store.get_player(first).experience == 0, "RAM progress does not write SQL")
	check(persistence.get_player_resource(first) == a, "dirty resource remains authoritative during reentry")
	persistence._process(59.0)
	check(store.batches == 0, "no early checkpoint")
	check(db.query("CREATE TEMP TRIGGER fail_second BEFORE UPDATE OF experience ON players WHEN NEW.player_id=%d BEGIN SELECT RAISE(ABORT,'intentional checkpoint failure'); END;" % second), "fail second row")
	check(not persistence.flush_progression(), "batch failure returned")
	check(store.get_player(first).level == 1 and store.get_player(second).experience == 0, "whole batch rolls back first row")
	check(persistence.dirty_progression.size() == 2 and a.level == 2, "failure retains RAM and both dirty flags")
	check(db.query("DROP TRIGGER fail_second;"), "remove fault")
	persistence._process(1.0)
	check(persistence.dirty_progression.is_empty() and store.batches == 2 and store.rows == 4, "periodic checkpoint batches only two dirty rows")
	check(store.get_player(first).level == 2 and store.get_player(first).experience == 10 and store.get_player(second).experience == 40, "final RAM values persisted")
	check(store.get_player(first).profile_status == profile and store.get_player(clean).experience == 0, "profile and clean character unchanged")
	persistence._process(60.0)
	check(store.batches == 2, "clean interval issues no transaction")
	a.add_experience(20)
	b.add_experience(20)
	persistence.mark_progression_dirty(a)
	persistence.mark_progression_dirty(b)
	check(persistence.flush_progression(first), "forced owner checkpoint")
	check(not persistence.dirty_progression.has(first) and persistence.dirty_progression.has(second), "single-owner flush retains other dirty character")
	check(store.get_player(first).experience == 30 and store.get_player(second).experience == 40, "forced checkpoint saves only owner")
	# Simulate losing RAM after a crash: SQL stays at the last accepted checkpoint.
	c.add_experience(20)
	persistence.mark_progression_dirty(c)
	check(store.get_player(clean).experience == 0, "dirty soft progression is not yet persisted")
	persistence.dirty_progression.erase(clean) # discard this character's in-memory state
	c = store.get_player(clean)
	check(c.experience == 0, "fresh load after losing RAM restores last checkpoint without replaying kills")
	check(db.query("DROP TRIGGER reject_full_save;"), "allow normal session save")
	check(db.query("DROP TRIGGER reject_profile_save;"), "allow session metadata save")
	check(persistence.save_all_connected({}) == 0, "shutdown checkpoint also flushes disconnected dirty refs")
	check(persistence.dirty_progression.is_empty() and store.get_player(second).experience == 60, "shutdown flush persists remaining offline progression")
	check(db.close_db() and db.open_db(), "reopen checkpoint")
	check(store.get_player(first).experience == 30 and store.get_player(second).experience == 60, "reopen restores last checkpoint")
	db.close_db()
	if not failed:
		print("CHECKPOINT_OK: RAM-only gains, dirty batch, narrow writes, rollback/retry, forced save, crash window, schema cleanup")
		get_tree().quit()
