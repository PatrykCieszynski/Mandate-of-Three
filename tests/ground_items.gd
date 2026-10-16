extends Node
## Real SQLite: full bag, replay, partial-write rollback and durable receipt.
var failed: bool = false

func check(ok: bool, description: String) -> void:
	if not ok:
		failed = true
		push_error("GROUND_ITEMS_FAILED: " + description)
		get_tree().quit(1)

func rolled_item(owner: int, uid: String, bonus: int) -> ItemInstance:
	var item := ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,[{"stat":"attack","value":bonus}])
	item.uid = uid
	return item

func _ready() -> void:
	check(MobDeathResult.owner_for_contributions({2:10,1:10})==1 and MobDeathResult.owner_for_contributions({1:10,2:10})==1,"reward ties use stable owner ID, not dictionary iteration order")
	check(MobDeathResult.owner_for_contributions({})==0,"no contributor means public reward")
	var db := SQLite.new()
	db.path = "res://.godot/verification/ground-items-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	check(db.open_db(), "open")
	WorldSchema.ensure_schema(db)
	var legacy := WorldStoreSqlite.new(db)
	var first: int = EconomyFixture.create_character(legacy,"ground_alpha", {"name": "Alpha", "skin": 1})
	var second: int = EconomyFixture.create_character(legacy,"ground_beta", {"name": "Beta", "skin": 1})
	var persistence := WorldDatabase.new()
	persistence.db = db
	persistence.store = legacy
	var store := ItemStoreSqlite.new(db)
	check(store.initialize_character(first).ok and store.initialize_character(second).ok, "starter")
	var uid: String = Crypto.new().generate_random_bytes(16).hex_encode()
	var filler: Array[String] = []
	while store._free_bag_position(first, ItemDefinitions.IRON_SWORD.inventory_height) >= 0:
		var position: int = store._free_bag_position(first, ItemDefinitions.IRON_SWORD.inventory_height)
		var item: ItemInstance = ItemInstance.create(ItemDefinitions.IRON_SWORD, first, [])
		check(EconomyFixture.insert_item(store,item, position), "fill bag")
		filler.append(item.uid)
	check(store.claim_ground_item(first, uid, rolled_item(first,uid,5)).get("error", "") == "bag_full", "full bag rejected")
	check(db.query("SELECT COUNT(*) AS n FROM ground_item_claims;") and db.query_result[0].n == 0, "failed pickup leaves no receipt")
	check(EconomyFixture.destroy_item(db,filler[0]),"free slot")
	check(db.query_with_bindings("DELETE FROM item_instances WHERE uid=?;", [filler[0]]), "remove fixture")
	check(db.query("CREATE TEMP TRIGGER fail_ground BEFORE INSERT ON item_custody BEGIN SELECT RAISE(ABORT,'intentional ground placement failure'); END;"), "fault injection")
	var operation := persistence.claim_ground_item_operation(first, uid, rolled_item(first,uid,5))
	check(operation.response().get("error", "") == "storage" and not operation.new_commit and operation.changed_accounts.is_empty(), "partial write fails without a mutation fact")
	check(db.query_with_bindings("SELECT COUNT(*) AS n FROM item_instances WHERE uid=?;", [uid]) and db.query_result[0].n == 0, "rollback item")
	check(db.query("SELECT COUNT(*) AS n FROM ground_item_claims;") and db.query_result[0].n == 0, "rollback receipt")
	check(db.query("DROP TRIGGER fail_ground;"), "end fault")
	operation = persistence.claim_ground_item_operation(first, uid, rolled_item(first,uid,5))
	var claimed := operation.response()
	check(operation.new_commit and not operation.receipt_replay and operation.character_id == first and operation.changed_accounts == PackedInt64Array([legacy.resolve_account_id(first)]), "pickup result identifies one newly committed account")
	check(claimed.ok and claimed.uid == uid, "pickup identity")
	operation = persistence.claim_ground_item_operation(second, uid, rolled_item(second,uid,9))
	check(operation.response().get("error", "") == "claimed" and not operation.new_commit and not operation.receipt_replay and operation.changed_accounts.is_empty(), "second owner claim denied without replay success or mutation")
	var persisted: Dictionary = store.inventory(first)
	var found: bool = false
	for item: Dictionary in persisted.items:
		if item.uid == uid:
			found = item.owner_character_id == first and item.definition_id == "iron_sword" and item.stats.attack == 15 and item.location == "bag" and item.amount == 1
	check(found, "pickup preserves server definition, bonus and owner")
	check(db.close_db() and db.open_db(), "reopen")
	store = ItemStoreSqlite.new(db)
	check(store.inventory(first) == persisted, "persistent exact item")
	check(store.claim_ground_item(first, uid, rolled_item(first,uid,1)).get("error", "") == "claimed", "durable replay denial")
	check(store.inventory(second).items.size() == 2, "loser receives nothing")
	var generic := ItemInstance.create(ItemDefinitions.UPGRADE_ORE,second,[])
	generic.amount = 2
	var generic_uid: String = generic.uid
	check(store.claim_ground_item(first,generic_uid,generic).get("error","")=="owner","claim validates the prepared item's owner")
	check(store.claim_ground_item(second,generic_uid,generic).ok,"claim accepts an application-prepared non-sword item")
	var generic_found := false
	for item: Dictionary in store.inventory(second).items:
		if item.uid==generic_uid: generic_found = item.definition_id==str(ItemDefinitions.UPGRADE_ORE.definition_id) and item.amount==2 and item.affixes.is_empty()
	check(generic_found,"SQL claim preserves definition/quantity instead of generating legacy sword loot")

	# P3a: ordinary materials and variable-size stacks use the same ground UID flow.
	var ground := GroundLootSystem.new()
	var ore_uid: String = ground.spawn_resolved_item(Vector3.ZERO, second, "Beta", 1000, ItemDefinitions.UPGRADE_ORE.definition_id, 3, [])
	check(ItemInstance.valid_uid(ore_uid) and ground.drops.has(ore_uid), "generic material ground entry creates one UID")
	var ore_drop: Dictionary = ground.drops[ore_uid]
	var prepared_ore := GroundLootSystem.prepare_claim_item(ore_uid, second, ore_drop)
	check(prepared_ore != null and prepared_ore.amount == 3 and prepared_ore.affixes.is_empty(), "prepared claim conserves amount and no affixes")
	operation = persistence.claim_ground_item_operation(second, ore_uid, prepared_ore)
	check(operation.new_commit and operation.response().ok, "generic stack pickup persists atomically")
	check(persistence.claim_ground_item_operation(second, ore_uid, GroundLootSystem.prepare_claim_item(ore_uid, second, ore_drop)).response().get("error", "") == "claimed", "replay cannot mint stack twice")
	var saw_stack := false
	for item: Dictionary in store.inventory(second).items:
		if item.uid == ore_uid: saw_stack = item.amount == 3 and item.definition_id == "upgrade_ore" and item.affixes.is_empty()
	check(saw_stack, "generic ground stack amount survives SQLite receipt")
	check(ground.spawn_resolved_item(Vector3.ZERO, second, "Beta", 1000, ItemDefinitions.UPGRADE_ORE.definition_id, 201, []).is_empty(), "cannot exceed stack limit")
	check(ground.spawn_resolved_item(Vector3.ZERO, second, "Beta", 1000, &"missing_item", 1, []).is_empty(), "reject unknown item definition")
	check(ground.spawn_resolved_item(Vector3.ZERO, second, "Beta", 1000, ItemDefinitions.UPGRADE_ORE.definition_id, 1, [{"stat":"attack","value":1}]).is_empty(), "materials reject weapon affixes")
	var mutable_rolls: Array = [{"stat":"attack","value":6}]
	var sword_uid := ground.spawn_resolved_item(Vector3.ZERO, second, "Beta", 1000, ItemDefinitions.IRON_SWORD.definition_id, 1, mutable_rolls)
	check(ItemInstance.valid_uid(sword_uid), "rolled equipment ground entry is valid")
	mutable_rolls[0].value = 99
	var frozen := GroundLootSystem.prepare_claim_item(sword_uid, second, ground.drops[sword_uid])
	check(frozen != null and frozen.affixes[0].value == 6, "ground item freezes rolled affixes against caller changes")
	check(GroundLootSystem.attack_for_drop(ItemDefinitions.IRON_SWORD, ground.drops[sword_uid]) == 16, "presentation derives attack for equipment only")
	check(GroundLootSystem.attack_for_drop(ItemDefinitions.UPGRADE_ORE, ore_drop) == 0, "material is not a weapon")
	check(ground.spawn_item(Vector3.ZERO, second, "Beta", 1000, ItemDefinitions.IRON_SWORD.definition_id, 5).length() == 32, "old sword helper remains compatible")
	check(GroundLootSystem.prepare_claim_item("bad-uid", second, ore_drop) == null, "invalid UID rejected before SQL")
	persistence.free()
	db.close_db()
	if not failed:
		print("GROUND_ITEMS_OK: full bag, partial write rollback, exact UID, replay and reopen")
		get_tree().quit()
