extends Node
var db:=SqliteSoci.new()
func _ready() -> void:
	db.path="res://.godot/verification/exchange-ledger.db";DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
	assert(db.open_db());WorldSchema.ensure_schema(db)
	var world:=WorldStoreSqlite.new(db)
	var owner:=EconomyFixture.create_character(world,"ledger",{"name":"Ledger","skin":1})
	var alt:=EconomyFixture.create_character(world,"ledger",{"name":"Alt","skin":1})
	var other:=EconomyFixture.create_character(world,"other",{"name":"Other","skin":1})
	assert(MarketSearchSqlite.ensure_schema(db))
	assert(db.query("CREATE TEMP TRIGGER fail_ledger BEFORE INSERT ON meta WHEN NEW.value='21' BEGIN SELECT RAISE(ABORT,'ledger migration fault'); END;"))
	assert(not ExchangeStoreSqlite.ensure_ledger_schema(db));assert(db.query("DROP TRIGGER fail_ledger;"));assert(ExchangeStoreSqlite.ensure_ledger_schema(db))
	var items:=ItemStoreSqlite.new(db)
	var exchange:=ExchangeStoreSqlite.new(db)
	var ore:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,owner,[]);ore.amount=100
	assert(EconomyFixture.insert_item(items,ore,0))
	assert(exchange.deposit(other,"foreign",ore.uid,0,100,"bag").error=="owner")
	for fault: String in ["BEFORE INSERT ON exchange_assets","BEFORE DELETE ON item_custody","BEFORE DELETE ON item_instances","BEFORE INSERT ON market_commands"]:
		assert(db.query("CREATE TEMP TRIGGER fail_deposit %s BEGIN SELECT RAISE(ABORT,'ledger deposit fault'); END;" % fault))
		assert(exchange.deposit(owner,"deposit",ore.uid,0,100,"bag").error=="storage")
		assert(items.inventory(owner).items[0].amount==100 and exchange.ledger(owner).assets[0].free==0)
		assert(db.query("DROP TRIGGER fail_deposit;"))
	assert(exchange.deposit(owner,"deposit",ore.uid,0,100,"bag").ok)
	assert(exchange.deposit(owner,"deposit",ore.uid,0,100,"bag").ok and exchange.ledger(alt).assets[0].free==100,"same-account receipt prevents repeated deposit")
	for fault: String in ["BEFORE UPDATE ON exchange_assets","BEFORE INSERT ON item_instances","BEFORE INSERT ON item_custody","BEFORE INSERT ON market_commands"]:
		assert(db.query("CREATE TEMP TRIGGER fail_withdraw %s BEGIN SELECT RAISE(ABORT,'ledger withdrawal fault'); END;" % fault))
		assert(exchange.withdraw(alt,"withdraw","upgrade_ore",35,"bag").error=="storage")
		assert(items.inventory(alt).items.is_empty() and exchange.ledger(owner).assets[0].free==100)
		assert(db.query("DROP TRIGGER fail_withdraw;"))
	var withdrawn:=exchange.withdraw(alt,"withdraw","upgrade_ore",35,"bag")
	assert(withdrawn.ok and exchange.withdraw(alt,"withdraw","upgrade_ore",35,"bag").ok)
	assert(exchange.ledger(owner).assets[0].free==65 and items.inventory(alt).items[0].amount==35,"100-35=65, no duplicated stack")
	var storage:=AccountStorageSqlite.new(db)
	assert(storage.transfer(alt,withdrawn.uid,0,"inventory","storage",0).ok)
	assert(exchange.deposit(owner,"storage_deposit",withdrawn.uid,1,10,"account_storage").ok)
	assert(storage.snapshot(alt).items[0].amount==25 and exchange.ledger(owner).assets[0].free==75)
	assert(exchange.deposit(owner,"storage_stale",withdrawn.uid,1,10,"account_storage").error=="stale")
	var enriched:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,owner,[{"stat":"attack","value":1}])
	assert(EconomyFixture.insert_item(items,enriched,0))
	assert(exchange.deposit(owner,"enriched",enriched.uid,0,1,"bag").error=="not_fungible")
	assert(exchange.withdraw(owner,"badasset","iron_sword",1,"bag").error=="request")
	assert(db.query("BEGIN IMMEDIATE;"));assert(exchange.reserve_in_transaction(world.resolve_account_id(owner),"upgrade_ore",60).ok);assert(db.query("COMMIT;"))
	assert(exchange.ledger(owner).assets[0].free==15 and exchange.ledger(owner).assets[0].reserved==60)
	assert(exchange.withdraw(owner,"reserved","upgrade_ore",16,"bag").error=="funds")
	assert(db.query("BEGIN IMMEDIATE;"));assert(exchange.reserve_in_transaction(world.resolve_account_id(owner),"yang",1400,90).ok);assert(db.query("COMMIT;"))
	var wallet:=WalletStoreSqlite.new(db)
	assert(wallet.spend(world.resolve_account_id(owner),0,191).error=="funds","NPC/upgrade spend cannot use reserved Yang")
	assert(wallet.spend(world.resolve_account_id(owner),0,190).ok)
	assert(db.query("BEGIN IMMEDIATE;"));assert(exchange.release_in_transaction(world.resolve_account_id(owner),"yang",1400));assert(exchange.release_in_transaction(world.resolve_account_id(owner),"upgrade_ore",60));assert(db.query("COMMIT;"))
	assert(exchange.ledger(owner).assets[0].free==75 and exchange.ledger(owner).assets[0].reserved==0)
	assert(exchange.withdraw(owner,"claim","upgrade_ore",20,"claim").ok and MarketStoreSqlite.new(db).mine(alt).claims[0].amount==20)
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	assert(db.close_db() and db.open_db() and ExchangeStoreSqlite.ensure_ledger_schema(db))
	assert(exchange.ledger(alt).assets[0].free==55 and exchange.withdraw(alt,"withdraw","upgrade_ore",35,"bag").uid==withdrawn.uid)
	# Every newly tradeable material must be visible in the Exchange ledger and
	# withdrawable through the same asset IDs that ordinary deposits accept.
	var materials: Array[ItemDefinition] = [
		ItemDefinitions.FOREST_RESIN, ItemDefinitions.BEAST_HIDE,
		ItemDefinitions.WOLF_FANG, ItemDefinitions.BANDIT_TOKEN
	]
	var asset_names: Array[String] = []
	for index: int in materials.size():
		var definition: ItemDefinition = materials[index]
		var asset_id := str(definition.definition_id)
		assert(MarketRequestRules.asset_definition(asset_id) == definition)
		var material := ItemInstance.create(definition, owner, [])
		material.amount = 3
		assert(EconomyFixture.insert_item(items, material, 5 + index), "new material seeded")
		assert(exchange.deposit(owner, "new_deposit_" + asset_id, material.uid, 0, 3, "bag").ok, "new material deposit")
		var account_ledger := exchange.ledger(alt)
		assert(account_ledger.ok)
		var listed: bool = false
		for asset: Dictionary in account_ledger.assets:
			if asset.asset_id == asset_id:
				listed = asset.name == definition.item_name and asset.stack_limit == definition.stack_limit and asset.free == 3 and asset.reserved == 0
		assert(listed, "deposited asset must be visible through UI ledger")
		assert(MarketRequestRules.valid_command("withdraw", {"command_id": "valid_" + asset_id,
			"asset_id": asset_id, "amount": 2, "destination": "bag"}), "withdraw selector accepts asset")
		var payout := exchange.withdraw(alt, "new_withdraw_" + asset_id, asset_id, 2, "bag")
		assert(payout.ok, "new material can be withdrawn through regular Exchange")
		assert(exchange.withdraw(alt, "new_withdraw_" + asset_id, asset_id, 2, "bag").uid == payout.uid, "withdraw receipt replay")
		var persisted: bool = false
		for item: Dictionary in items.inventory(alt).items:
			if item.uid == payout.uid:
				persisted = item.definition_id == asset_id and item.amount == 2
		assert(persisted, "withdrawn material must persist with exact amount and definition")
		var remaining: bool = false
		for asset: Dictionary in exchange.ledger(owner).assets:
			if asset.asset_id == asset_id:
				remaining = asset.free == 1 and asset.reserved == 0
		assert(remaining, "post-withdrawal balance remains visible")
		assert(db.query_with_bindings("SELECT free,reserved FROM exchange_assets WHERE account_id=? AND asset_id=?;", [world.resolve_account_id(owner), asset_id]))
		assert(db.query_result.size() == 1 and db.query_result[0].free == 1 and db.query_result[0].reserved == 0, "SQL ledger and snapshot agree")
		asset_names.append(asset_id)
	assert(asset_names.size() == 4)
	assert(exchange.ledger(owner).assets.size() == 5, "only canonical fungible assets are shown, including zero balances")
	print("EXCHANGE_LEDGER_OK whitelist, bag/storage, 100-35 conservation, reserve/spend guard, claims, faults, retry/reopen")
	db.close_db();DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path));get_tree().quit()
