extends Node
var db: SQLite
var persistence: WorldDatabase
var character_id: int
var recipe: UpgradeDefinition = UpgradeDefinitions.BASIC
func seed_item(definition: ItemDefinition, amount: int = 1) -> String:
	var item: ItemInstance = ItemInstance.create(definition,character_id,[])
	item.amount = amount
	assert(db.query("BEGIN IMMEDIATE;"))
	assert(persistence.item_store.receive_item_in_transaction(item).ok)
	assert(db.query("COMMIT;"))
	return item.uid
func state() -> Dictionary:
	assert(db.query_with_bindings("SELECT yang FROM wallets WHERE character_id=?;",[character_id]))
	var balance: int = int(db.query_result[0].yang)
	return {"items":persistence.item_store.inventory(character_id),"db_yang":balance,"ram":persistence.runtime_wallets[character_id].duplicate(true),"dirty":persistence.dirty_wallet.has(character_id)}
func _ready() -> void:
	assert(recipe.validation_errors().is_empty())
	var bad: UpgradeDefinition = recipe.duplicate(true)
	bad.to_level = 2
	assert("unsupported_upgrade" in bad.validation_errors())
	db = SQLite.new()
	db.path = "res://.godot/verification/upgrade-%s.db" % Crypto.new().generate_random_bytes(8).hex_encode()
	assert(db.open_db())
	WorldSchema.ensure_schema(db)
	persistence = WorldDatabase.new()
	persistence.db = db
	persistence.store = WorldStoreSqlite.new(db)
	persistence.item_store = ItemStoreSqlite.new(db)
	persistence.wallet_store = WalletStoreSqlite.new(db)
	character_id = persistence.store.create_player_character("upgrade_fixture",{"name":"Smith tester","skin":1})
	assert(persistence.load_wallet(character_id))
	var sword: String = seed_item(ItemDefinitions.IRON_SWORD)
	assert(persistence.add_yang(character_id,2100))
	var before: Dictionary = state()
	assert(persistence.upgrade_item(character_id,recipe,sword,0).error == "material")
	assert(state() == before, "Missing material cannot commit pending Yang")
	var ore: String = seed_item(ItemDefinitions.UPGRADE_ORE,2)
	before = state()
	assert(persistence.upgrade_item(character_id,recipe,sword,1).error == "stale")
	assert(persistence.upgrade_item(character_id,recipe,ore,0).error == "unsupported_item")
	assert(state() == before)
	assert(db.query("CREATE TEMP TRIGGER fail_upgrade BEFORE UPDATE ON item_instances WHEN NEW.definition_id='iron_sword' BEGIN SELECT RAISE(ABORT,'upgrade fault'); END;"))
	assert(persistence.upgrade_item(character_id,recipe,sword,0).error == "storage")
	assert(state() == before, "Late sword write failure rolls back consumed material, pending Yang and spend, including RAM dirty state")
	assert(db.query("DROP TRIGGER fail_upgrade;"))
	assert(db.query("CREATE TEMP TRIGGER fail_wallet BEFORE UPDATE ON wallets BEGIN SELECT RAISE(ABORT,'wallet fault'); END;"))
	assert(persistence.upgrade_item(character_id,recipe,sword,0).error == "storage")
	assert(state() == before, "Wallet failure restores material")
	assert(db.query("DROP TRIGGER fail_wallet;"))
	var result: Dictionary = persistence.upgrade_item(character_id,recipe,sword,0)
	assert(result.ok and result.balance == 1100)
	var after: Dictionary = state()
	assert(after.db_yang == 1100 and after.ram.wallet_balance == 1100 and after.ram.pending_currency_delta == 0 and not after.dirty)
	var upgraded: Dictionary
	for item: Dictionary in after.items.items:
		if item.uid == sword:
			upgraded = item
			assert(item.upgrade_level == 1 and item.revision == 1 and item.bag_position == 0 and item.location == "bag" and item.stats.attack == 12)
		elif item.uid == ore: assert(item.amount == 1 and item.revision == 1)
	assert(not upgraded.is_empty())
	assert(persistence.upgrade_item(character_id,recipe,sword,0).error == "stale")
	assert(persistence.upgrade_item(character_id,recipe,sword,1).error == "upgrade_level")
	assert(state() == after, "Replay never consumes twice")
	var next_sword: String = seed_item(ItemDefinitions.IRON_SWORD)
	assert(persistence.item_store.change_equipment(character_id,next_sword,0,"equip").ok)
	before = state()
	assert(persistence.upgrade_item(character_id,recipe,next_sword,1).error == "placement")
	assert(state() == before)
	assert(persistence.item_store.change_equipment(character_id,next_sword,1,"unequip").ok)
	# Whole-stack deletion also rolls back if the later item write fails.
	before = state()
	assert(db.query("CREATE TEMP TRIGGER fail_upgrade BEFORE UPDATE ON item_instances WHEN NEW.definition_id='iron_sword' BEGIN SELECT RAISE(ABORT,'upgrade fault'); END;"))
	assert(persistence.upgrade_item(character_id,recipe,next_sword,2).error == "storage")
	assert(state() == before)
	assert(db.query("DROP TRIGGER fail_upgrade;"))
	assert(persistence.upgrade_item(character_id,recipe,next_sword,2).ok)
	assert(db.query_with_bindings("SELECT uid FROM item_instances WHERE uid=?;",[ore]) and db.query_result.is_empty())
	assert(db.query_with_bindings("SELECT item_uid FROM item_placements WHERE item_uid=?;",[ore]) and db.query_result.is_empty())
	var poor_sword: String = seed_item(ItemDefinitions.IRON_SWORD)
	seed_item(ItemDefinitions.UPGRADE_ORE)
	before = state()
	assert(persistence.upgrade_item(character_id,recipe,poor_sword,0).error == "funds")
	assert(state() == before)
	var other: int = persistence.store.create_player_character("other",{"name":"Other","skin":1})
	assert(persistence.load_wallet(other) and persistence.add_yang(other,1000))
	assert(persistence.upgrade_item(other,recipe,poor_sword,0).error == "owner")
	assert(state() == before)
	assert(db.close_db() and db.open_db())
	assert(state() == before,"Final item/material/wallet state survives database reopen")
	db.close_db()
	persistence.free()
	print("UPGRADE_TRANSACTION_OK: UID/revision/ownership/Inventory, stack consumption, pending Yang, rollback, replay and durability")
	get_tree().quit()
