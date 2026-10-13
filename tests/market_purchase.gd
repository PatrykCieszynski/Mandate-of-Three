extends Node
## Uncovered economy contract: atomic two-wallet settlement, offline seller and retry.
var db := SQLite.new()
var store: WorldStoreSqlite
var market: MarketStoreSqlite
var items: ItemStoreSqlite
var persistence: WorldDatabase
func balance(account: int) -> int:
	assert(db.query_with_bindings("SELECT yang FROM account_wallets WHERE account_id=?;",[account]))
	return int(db.query_result[0].yang)
func _ready() -> void:
	db.path="res://.godot/verification/market-purchase.db"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
	assert(db.open_db());WorldSchema.ensure_schema(db)
	store=WorldStoreSqlite.new(db)
	var seller:=EconomyFixture.create_character(store,"seller",{"name":"Seller","skin":1})
	var alt:=EconomyFixture.create_character(store,"seller",{"name":"Alt","skin":1})
	var buyer:=EconomyFixture.create_character(store,"buyer",{"name":"Buyer","skin":1})
	var rival:=EconomyFixture.create_character(store,"rival",{"name":"Rival","skin":1})
	items=ItemStoreSqlite.new(db)
	for owner: int in [seller,alt,buyer,rival]: assert(items.initialize_character(owner).ok)
	market=MarketStoreSqlite.new(db)
	persistence=WorldDatabase.new();add_child(persistence);persistence.db=db;persistence.store=store;persistence.item_store=items;persistence.wallet_store=WalletStoreSqlite.new(db);EconomyFixture.prepare(persistence)
	assert(persistence.load_wallet(seller) and persistence.load_wallet(buyer))
	assert(persistence.add_yang(seller,33) and persistence.add_yang(buyer,90))
	var seller_account:=store.resolve_account_id(seller)
	var buyer_account:=store.resolve_account_id(buyer)
	var item: Dictionary=items.inventory(seller).items[0]
	var listed:=market.list_item(seller,"list",item.uid,item.revision,0,100)
	assert(listed.ok)
	var payload: Dictionary={"command_id":"buy","shop_id":listed.shop_id,"offer_id":listed.offer_id,"revision":0,"price":100}
	assert(persistence.market_command(alt,"buy",payload).error=="self_trade")
	assert(market.configure(seller,"pause",0,"Shop","paused").ok)
	assert(persistence.market_command(buyer,"buy",payload).error=="paused")
	payload.command_id="purchase"
	assert(market.configure(seller,"resume",1,"Shop","active").ok)
	assert(market.purchase(buyer,"stale",listed.shop_id,listed.offer_id,0,101,{}).error=="stale")
	while items._free_bag_position(rival,2)>=0:
		assert(EconomyFixture.insert_item(items,ItemInstance.create(ItemDefinitions.IRON_SWORD,rival,[]),items._free_bag_position(rival,2)))
	assert(market.purchase(rival,"full",listed.shop_id,listed.offer_id,0,100,{}).error=="inventory_full")
	assert(balance(store.resolve_account_id(rival))==1500 and market.mine(seller).offers.size()==1,"full bag does not charge or consume offer")
	var before:=items.inventory(buyer)
	for fault: String in ["BEFORE UPDATE ON account_wallets","BEFORE DELETE ON shop_cells","BEFORE UPDATE ON item_instances","BEFORE UPDATE ON item_custody","BEFORE DELETE ON shop_offers","BEFORE INSERT ON market_commands"]:
		assert(db.query("CREATE TEMP TRIGGER fail_sale %s BEGIN SELECT RAISE(ABORT,'purchase stage fault'); END;" % fault))
		assert(persistence.market_command(buyer,"buy",payload).error=="storage")
		assert(balance(seller_account)==1500 and balance(buyer_account)==1500 and items.inventory(buyer)==before and market.mine(seller).offers.size()==1)
		assert(persistence.wallet_balance(seller)==1533 and persistence.wallet_balance(buyer)==1590,"rollback retains both pending incomes")
		assert(db.query("DROP TRIGGER fail_sale;"))
	var result:=persistence.market_command(buyer,"buy",payload)
	assert(result.ok and balance(buyer_account)==1490 and balance(seller_account)==1633)
	assert(persistence.wallet_balance(buyer)==1490 and persistence.wallet_balance(seller)==1633)
	assert(items.inventory(buyer).items.any(func(i: Dictionary)->bool:return i.uid==item.uid and i.revision==2))
	assert(market.purchase(rival,"rival",listed.shop_id,listed.offer_id,0,100,{}).error=="unavailable")
	assert(persistence.add_yang(buyer,17) and persistence.add_yang(seller,19))
	assert(persistence.market_command(buyer,"buy",payload).ok)
	assert(persistence.wallet_balance(buyer)==1507 and persistence.wallet_balance(seller)==1652,"replayed receipt never restores stale committed balances")
	assert(persistence.flush_wallet())
	assert(db.close_db() and db.open_db());assert(MarketStoreSqlite.ensure_schema(db))
	assert(market.purchase(buyer,"purchase",listed.shop_id,listed.offer_id,0,100,{}).ok and balance(buyer_account)==1507)
	# Offline seller has no RAM wallet. Credits still settle in the sale transaction.
	persistence.release_wallet(seller)
	item=items.inventory(seller).items[0]
	listed=market.list_item(seller,"offline_list",item.uid,item.revision,0,200)
	assert(persistence.market_command(buyer,"buy",{"command_id":"offline_buy","shop_id":listed.shop_id,"offer_id":listed.offer_id,"revision":0,"price":200}).ok)
	assert(balance(seller_account)==1852 and not persistence.runtime_wallets.has(seller_account))
	assert(db.query("PRAGMA foreign_key_check;") and db.query_result.is_empty())
	print("MARKET_PURCHASE_OK pending two-wallet commit, offline, fault rollback, self-account, stale, durable retry")
	db.close_db();DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path));get_tree().quit()
