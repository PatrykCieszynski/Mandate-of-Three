extends Node
## Uncovered economy contract: atomic two-wallet settlement, offline seller and retry.
var db := SQLite.new()
var store: WorldStoreSqlite
var market: MarketStoreSqlite
var items: ItemStoreSqlite
var persistence: WorldDatabase
var observed_accounts: Array[int]=[]
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
	# Offer-only listings have no public price, cannot be bought through the
	# authoritative RPC/store and remain in search/visitor results.
	var negotiating: Array = []
	for n: int in 2:
		var extra_item := ItemInstance.create(ItemDefinitions.IRON_SWORD,seller,[])
		assert(EconomyFixture.insert_item(items,extra_item,items._free_bag_position(seller,2)))
		var offered := market.list_item(seller,"offer_only_list_%d" % n,extra_item.uid,0,n*10,0)
		assert(offered.ok)
		negotiating.append({"uid":extra_item.uid,"offer":offered})
	var shop_view := market.mine(seller)
	assert(shop_view.offers.size()==2 and shop_view.offers.all(func(o: Dictionary)->bool:return o.price==null))
	assert(market.visit(int(negotiating[0].offer.shop_id)).offers.all(func(o: Dictionary)->bool:return o.price==null))
	var no_price_buy := {"command_id":"forged_offer_only_buy","shop_id":negotiating[0].offer.shop_id,"offer_id":negotiating[0].offer.offer_id,"revision":0,"price":1}
	assert(persistence.market_command(buyer,"buy",no_price_buy).error=="offer_only")
	assert(not MarketRequestRules.valid_command("buy",{"command_id":"invalid_zero","shop_id":negotiating[0].offer.shop_id,"offer_id":negotiating[0].offer.offer_id,"revision":0,"price":0}))
	assert(market.edit_offer(seller,"set_fixed",negotiating[0].offer.offer_id,0,0,120).ok)
	assert(market.mine(seller).offers.any(func(o: Dictionary)->bool:return o.price==120))
	assert(market.edit_offer(seller,"remove_fixed",negotiating[0].offer.offer_id,1,0,0).ok)
	assert(market.mine(seller).offers.all(func(o: Dictionary)->bool:return o.price==null))
	var criteria := {"definition_id":"iron_sword","upgrade_min":0,"upgrade_max":9,"price_min":0,"price_max":WalletStoreSqlite.MAX_YANG,"affix_filters":[],"sort":"price_asc","cursor":"","limit":1}
	var searcher := MarketSearchSqlite.new(db)
	var first_page := searcher.search(criteria)
	assert(first_page.ok and first_page.results.size()==1 and first_page.results[0].price==null and first_page.next_cursor.begins_with("0:"))
	criteria.cursor=first_page.next_cursor
	var second_page := searcher.search(criteria)
	assert(second_page.ok and second_page.results.size()==1 and second_page.results[0].price==null and second_page.results[0].offer_id!=first_page.results[0].offer_id)
	criteria.cursor=""
	criteria.price_min=1
	assert(searcher.search(criteria).results.is_empty(),"bounded positive-price search excludes negotiable listings")
	for n: int in 2:
		var listing: Dictionary=negotiating[n]
		assert(market.cancel_offer(seller,"offer_only_cancel_%d" % n,listing.offer.offer_id,2 if n==0 else 0).ok)
		assert(items.inventory(seller).items.any(func(i: Dictionary)->bool:return i.uid==listing.uid))
	assert(market.mine(seller).offers.is_empty() and market.mine(seller).claims.is_empty())
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
	var reader:=SQLite.new();reader.path=ProjectSettings.globalize_path(db.path);assert(reader.open_db())
	persistence.market_account_changed.connect(func(account: int)->void:
		assert(reader.query_with_bindings("SELECT yang FROM account_wallets WHERE account_id=?;",[account]) and not reader.query_result.is_empty(),"observer connection sees committed ledger")
		observed_accounts.append(account))
	# The application boundary must reject malformed direct callers, not rely on
	# the network adapter to prevent indexing/type errors or durable writes.
	assert(db.query("SELECT COUNT(*) AS n FROM market_commands;"))
	var receipt_count := int(db.query_result[0].n)
	for malformed: Dictionary in [{}, {"command_id":"bad", "uid":item.uid}, {"command_id":"bad", "shop_id":{}, "offer_id":listed.offer_id, "revision":0, "price":100}]:
		assert(persistence.market_command(buyer, "buy", malformed).error == "request")
	assert(persistence.market_command(buyer, "withdraw", {"command_id":"bad_asset", "asset_id":42, "amount":1, "destination":"bag"}).error == "request")
	var rejected_operation := persistence.market_operation(buyer, "buy", {})
	assert(rejected_operation.response().error == "request" and not rejected_operation.new_commit and not rejected_operation.receipt_replay and rejected_operation.changed_accounts.is_empty())
	assert(persistence.market_command(buyer, "open", {}).error == "request", "open is presentation, not an economic command")
	assert(db.query("SELECT COUNT(*) AS n FROM market_commands;") and int(db.query_result[0].n) == receipt_count)
	assert(observed_accounts.is_empty() and persistence.wallet_balance(buyer) == 1590)
	var before:=items.inventory(buyer)
	for fault: String in ["BEFORE UPDATE ON account_wallets","BEFORE DELETE ON shop_cells","BEFORE UPDATE ON item_instances","BEFORE UPDATE ON item_custody","BEFORE DELETE ON shop_offers","BEFORE INSERT ON market_commands"]:
		assert(db.query("CREATE TEMP TRIGGER fail_sale %s BEGIN SELECT RAISE(ABORT,'purchase stage fault'); END;" % fault))
		assert(persistence.market_command(buyer,"buy",payload).error=="storage")
		assert(balance(seller_account)==1500 and balance(buyer_account)==1500 and items.inventory(buyer)==before and market.mine(seller).offers.size()==1)
		assert(observed_accounts.is_empty(),"SQL rollback emits no success/account fact")
		assert(persistence.wallet_balance(seller)==1533 and persistence.wallet_balance(buyer)==1590,"rollback retains both pending incomes")
		assert(db.query("DROP TRIGGER fail_sale;"))
	var operation := persistence.market_operation(buyer, "buy", payload)
	var result := operation.response()
	assert(operation.operation_id == "purchase" and operation.character_id == buyer and operation.account_id == buyer_account)
	assert(operation.new_commit and not operation.receipt_replay and operation.changed_accounts.size() == 2)
	assert(buyer_account in operation.changed_accounts and seller_account in operation.changed_accounts)
	assert(seller_account in observed_accounts and buyer_account in observed_accounts,"World fact refreshes both accounts beyond current map")
	assert(result.ok and balance(buyer_account)==1490 and balance(seller_account)==1633)
	assert(persistence.wallet_balance(buyer)==1490 and persistence.wallet_balance(seller)==1633)
	assert(items.inventory(buyer).items.any(func(i: Dictionary)->bool:return i.uid==item.uid and i.revision==2))
	assert(market.purchase(rival,"rival",listed.shop_id,listed.offer_id,0,100,{}).error=="unavailable")
	assert(persistence.add_yang(buyer,17) and persistence.add_yang(seller,19))
	var notifications := observed_accounts.size()
	var replay := persistence.market_operation(buyer, "buy", payload)
	assert(replay.response().ok and not replay.new_commit and replay.receipt_replay and replay.changed_accounts.is_empty())
	assert(replay.operation_id == operation.operation_id and replay.account_id == operation.account_id)
	var lookup := persistence.market_operation(buyer, "receipt", {"command_id":payload.command_id})
	assert(lookup.response().ok and not lookup.new_commit and not lookup.receipt_replay and lookup.changed_accounts.is_empty())
	assert(observed_accounts.size() == notifications, "receipt/retry publishes no new committed account changes")
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
	reader.close_db();db.close_db();DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path));get_tree().quit()
