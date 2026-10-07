extends Node
## Real SQLite: full bag, replay, partial-write rollback and durable receipt.
var failed: bool = false

func check(ok: bool, description: String) -> void:
	if not ok:
		failed = true
		push_error("GROUND_ITEMS_FAILED: " + description)
		get_tree().quit(1)

func _ready() -> void:
	var db := SQLite.new()
	db.path = "res://.godot/verification/ground-items-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	check(db.open_db(), "open")
	WorldSchema.ensure_schema(db)
	var legacy := WorldStoreSqlite.new(db)
	var first: int = legacy.create_player_character("ground_alpha", {"name": "Alpha", "skin": 1})
	var second: int = legacy.create_player_character("ground_beta", {"name": "Beta", "skin": 1})
	var store := ItemStoreSqlite.new(db)
	check(store.initialize_character(first).ok and store.initialize_character(second).ok, "starter")
	var uid: String = Crypto.new().generate_random_bytes(16).hex_encode()
	var filler: Array[String] = []
	for position: int in range(2, 24):
		var item: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD, first, [])
		check(store._insert_item(item, position), "fill bag")
		filler.append(item.uid)
	check(store.claim_ground_item(first, uid, 5).get("error", "") == "bag_full", "full bag rejected")
	check(db.query("SELECT COUNT(*) AS n FROM ground_item_claims;") and db.query_result[0].n == 0, "failed pickup leaves no receipt")
	check(db.query_with_bindings("DELETE FROM item_placements WHERE item_uid=?;", [filler[0]]), "free slot")
	check(db.query_with_bindings("DELETE FROM item_instances WHERE uid=?;", [filler[0]]), "remove fixture")
	check(db.query("CREATE TEMP TRIGGER fail_ground BEFORE INSERT ON item_placements BEGIN SELECT RAISE(ABORT,'intentional ground placement failure'); END;"), "fault injection")
	check(store.claim_ground_item(first, uid, 5).get("error", "") == "storage", "partial write fails")
	check(db.query_with_bindings("SELECT COUNT(*) AS n FROM item_instances WHERE uid=?;", [uid]) and db.query_result[0].n == 0, "rollback item")
	check(db.query("SELECT COUNT(*) AS n FROM ground_item_claims;") and db.query_result[0].n == 0, "rollback receipt")
	check(db.query("DROP TRIGGER fail_ground;"), "end fault")
	var claimed: Dictionary = store.claim_ground_item(first, uid, 5)
	check(claimed.ok and claimed.uid == uid, "pickup identity")
	check(store.claim_ground_item(second, uid, 9).get("error", "") == "claimed", "second owner replay denied")
	var persisted: Dictionary = store.inventory(first)
	var found: bool = false
	for item: Dictionary in persisted.items:
		if item.uid == uid:
			found = item.owner_character_id == first and item.definition_id == "iron_sword" and item.stats.attack == 15 and item.location == "bag" and item.amount == 1
	check(found, "pickup preserves server definition, bonus and owner")
	check(db.close_db() and db.open_db(), "reopen")
	store = ItemStoreSqlite.new(db)
	check(store.inventory(first) == persisted, "persistent exact item")
	check(store.claim_ground_item(first, uid, 1).get("error", "") == "claimed", "durable replay denial")
	check(store.inventory(second).items.size() == 2, "loser receives nothing")
	db.close_db()
	if not failed:
		print("GROUND_ITEMS_OK: full bag, partial write rollback, exact UID, replay and reopen")
		get_tree().quit()
