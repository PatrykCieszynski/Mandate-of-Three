extends Node
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Vendor = preload("res://source/server/world/database/postgres/vendor_sell_store_postgres.gd")
const NpcSession = preload("res://source/server/world/database/postgres/npc_session_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
var db: Object
var store: RefCounted
var context: Dictionary
var connection: String

func wait_for(predicate: Callable) -> void:
	var due:=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<due: await get_tree().process_frame
	assert(predicate.call(),"bounded vendor concurrency fixture")

func seed_item(definition: ItemDefinition, amount: int=1, owner: int=99100) -> String:
	var item:=ItemInstance.create(definition,owner,[]);item.amount=amount
	assert(db.begin() and Items.new(db).receive_item_in_transaction(item).ok and db.commit())
	return item.uid

func basket(uids: Array, amount: int=1) -> Array:
	var rows: Array=Items.new(db).inventory(99100).items
	var result: Array=[]
	for uid: String in uids:
		var row: Dictionary=rows.filter(func(item: Dictionary)->bool:return item.uid==uid)[0]
		result.append({"uid":uid,"revision":row.revision,"amount":amount})
	return result

func quote(lines: Array) -> Dictionary:
	var plan:=VendorResolver.resolve(lines,Items.new(db).inventory(99100).items,VendorRecipes.definitions(),VendorRecipes.pools())
	assert(plan.ok,str(plan))
	return {"quote_id":Crypto.new().generate_random_bytes(16).hex_encode(),"lines":VendorResolver.cart(lines),"plan":plan,"version":VendorRecipes.version(),"npc":"blacksmith","service":"shop","expires_at":int(Time.get_unix_time_from_system())+30}

func state() -> Dictionary:
	return {"items":Items.new(db).inventory(99100),"wallet":Wallet.new(db).load_wallet(9910),"receipts":db.query("SELECT * FROM economy.market_commands ORDER BY command_id;").rows}

func fault(table: String,event: String="INSERT",deferred: bool=false) -> void:
	assert(db.execute("CREATE OR REPLACE FUNCTION economy.vendor_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'vendor fixture'; END; $$;").ok)
	assert(db.execute(("CREATE CONSTRAINT TRIGGER vendor_fault AFTER "+event+" ON economy."+table+" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.vendor_fault();") if deferred else ("CREATE TRIGGER vendor_fault BEFORE "+event+" ON economy."+table+" FOR EACH ROW EXECUTE FUNCTION economy.vendor_fault();")).ok)

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	db=ClassDB.instantiate("GodotSociDatabase")
	assert(db.open("postgresql",connection) and Schema.ensure_schema(db))
	assert(Wallet.new(db).initialize_account(9910).ok and Items.new(db).bind_character(99100,9910))
	assert(Wallet.new(db).initialize_account(9911).ok and Items.new(db).bind_character(99110,9911))
	var grant: Dictionary=Sessions.new(db).install_verified_grant(Sessions.identity_from_verified_ticket(9910,99100,"vendor-fixture"),0)
	assert(grant.ok)
	context=grant.context
	# Trusted fixture brings the granted session to ready before using stores.
	assert(db.execute("UPDATE economy.inventory_sessions SET phase='ready' WHERE account_id=9910;").ok)
	store=Vendor.new(db);store.authorize_session(context,"fixture-income")
	var ore:=seed_item(ItemDefinitions.UPGRADE_ORE,20)
	var sword:=seed_item(ItemDefinitions.IRON_SWORD)
	var books: Array=[]
	for i: int in 10: books.append(seed_item(ItemDefinitions.BOOK_AURA))
	var before:=state()
	var offer:=quote(basket([ore],3))
	for i: int in 30: assert(quote(basket([ore],3)).plan==offer.plan)
	assert(state()==before,"repeated basket preview cannot alter UID, amount, revision or money")
	var sold: Dictionary=store.sell(99100,7,offer,"partial")
	assert(sold.ok and sold.wallet_states[0].pending_applied==7)
	assert(int(sold.yang)==3*ItemDefinitions.UPGRADE_ORE.vendor_price)
	var row: Dictionary=Items.new(db).inventory(99100).items.filter(func(item: Dictionary)->bool:return item.uid==ore)[0]
	assert(row.amount==17 and row.revision==1)
	before=state()
	assert(store.sell(99100,999,offer,"partial")==sold and store.receipt_replay and state()==before)
	var other:=quote(basket([ore],1))
	assert(store.sell(99100,0,other,"partial").error=="command_conflict")
	var stale:=other.duplicate(true);stale.lines[0].revision=0
	assert(store.sell(99100,0,stale,"stale").error=="stale" and state()==before)
	other.expires_at=0
	assert(store.sell(99100,0,other,"expired").error=="quote_expired" and state()==before)
	other=quote(basket([ore],1));other.version="old"
	assert(store.sell(99100,0,other,"content").error=="quote_stale")
	var mixed:=basket(books.slice(0,5));mixed.append_array(basket([sword]))
	offer=quote(mixed);before=state()
	for stage: Dictionary in [{"table":"item_custody","event":"INSERT"},{"table":"account_wallets","event":"UPDATE"},{"table":"market_commands","event":"INSERT"}]:
		fault(stage.table,stage.event)
		assert(store.sell(99100,11,offer,"fault-"+stage.table).error=="storage" and state()==before,"all item, wallet and receipt writes roll back")
		assert(db.execute("DROP TRIGGER vendor_fault ON economy."+stage.table+";").ok)
	sold=store.sell(99100,11,offer,"mixed")
	assert(sold.ok and sold.rewards.size()==1 and int(sold.yang)==ItemDefinitions.IRON_SWORD.vendor_price)
	before=state()
	# Lose response, close connection, reconstruct owner and recover same UID/draw.
	db.close();assert(db.open("postgresql",connection))
	store=Vendor.new(db);store.authorize_session(context,"different-capture")
	assert(store.sell(99100,999,offer,"mixed")==sold and state()==before)
	assert(NpcSession.new(db).receipt(context,99100,"sell","mixed")==sold)
	assert(not Items.new(db).inventory(99100).items.any(func(item: Dictionary)->bool:return item.uid in books.slice(0,5) or item.uid==sword))
	# A rejected COMMIT remains unknown; resolve receipt before explicit retry.
	offer=quote(basket(books.slice(5,10)));before=state()
	fault("market_commands","INSERT",true)
	assert(store.sell(99100,0,offer,"commit-fault").get("outcome_unknown",false) and not db.is_open())
	assert(db.open("postgresql",connection))
	assert(state()==before and NpcSession.new(db).receipt(context,99100,"sell","commit-fault").error=="unknown_command")
	assert(db.execute("DROP TRIGGER vendor_fault ON economy.market_commands;").ok)
	assert(store.sell(99100,0,offer,"commit-fault").ok)
	# Exact fresh-command duplicate basket cannot consume inputs twice.
	assert(not store.sell(99100,0,offer,"second-command").ok)
	# Independent native sessions race on account custody. Exact command replay
	# returns the same result; distinct commands cannot both consume one stack.
	var pool:=Executor.new()
	assert(pool.start(connection,2,4))
	await wait_for(func()->bool:pool.poll();return pool.is_ready())
	offer=quote(basket([ore],1))
	var events: Array=[]
	for i: int in 2: assert(pool.submit_npc(context,"sell","concurrent-same",{"quote":offer},0,"0123456789abcdef0123456789abcdef").queued)
	await wait_for(func()->bool:events.append_array(pool.poll());return events.size()==2)
	assert(events[0].result.ok and events[0].result==events[1].result)
	assert(events.filter(func(event: Dictionary)->bool:return event.get("committed",false) and not event.get("receipt_replay",false)).size()==1)
	offer=quote(basket([ore],1));events=[]
	for i: int in 2: assert(pool.submit_npc(context,"sell","concurrent-"+str(i),{"quote":offer},0,"0123456789abcdef0123456789abcdef").queued)
	await wait_for(func()->bool:events.append_array(pool.poll());return events.size()==2)
	assert(events.filter(func(event: Dictionary)->bool:return event.result.ok).size()==1)
	pool.begin_drain()
	await wait_for(func()->bool:pool.poll();return pool.is_stopped())
	var unavailable:=quote(basket([ore],1));before=state()
	db.close()
	assert(not store.sell(99100,0,unavailable,"offline-db").ok)
	assert(db.open("postgresql",connection) and state()==before)
	# Equipped inputs are rejected even when the quote predates equipping.
	var gear:=seed_item(ItemDefinitions.IRON_SWORD)
	offer=quote(basket([gear]))
	assert(db.begin())
	assert(db.execute("UPDATE economy.item_custody SET location='equipment',position=-1,equipment_slot='weapon' WHERE uid=:uid;",{"uid":gear}).ok)
	assert(db.commit())
	before=state()
	assert(store.sell(99100,0,offer,"equipped").error=="owner" and state()==before)
	# Fill the bag, then consume five books and place one reward in freed space.
	books=[]
	for i: int in 5: books.append(seed_item(ItemDefinitions.BOOK_CHARGE))
	while true:
		var item:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,99100,[])
		assert(db.begin())
		var inserted: Dictionary=Items.new(db).receive_item_in_transaction(item)
		if not inserted.ok:
			assert(inserted.error=="inventory_full" and db.rollback());break
		assert(db.commit())
	offer=quote(basket(books));assert(store.sell(99100,0,offer,"full-bag").ok)
	# Future stackable recipe input: consuming part of a stack frees no cell.
	# Test-only tag assignment exercises genuine capacity failure without adding
	# a second live recipe or relying on random reward identity.
	for i: int in 4: seed_item(ItemDefinitions.UPGRADE_ORE)
	var ore_definition: ItemDefinition=ItemDefinitions.UPGRADE_ORE
	var previous_tags:=ore_definition.recipe_tags.duplicate()
	ore_definition.recipe_tags=[&"skill_book"]
	offer=quote(basket([ore],5));before=state()
	assert(store.sell(99100,0,offer,"no-reward-space").error=="inventory_full" and state()==before)
	ore_definition.recipe_tags=previous_tags
	# Wallet capacity rejects the WHOLE basket, never clips the sale proceeds.
	var actual_balance: int=Wallet.new(db).load_wallet(9910).balance
	assert(db.execute("UPDATE economy.account_wallets SET yang=:value WHERE account_id=9910;",{"value":Wallet.MAX_YANG}).ok)
	offer=quote(basket([ore],1));before=state()
	assert(store.sell(99100,0,offer,"wallet-full").error=="overflow" and state()==before)
	assert(db.execute("UPDATE economy.account_wallets SET yang=:value WHERE account_id=9910;",{"value":actual_balance}).ok)
	# Session revocation is fenced in the transaction even for a held quote.
	offer=quote(basket([ore],1));before=state()
	assert(db.execute("UPDATE economy.inventory_sessions SET phase='revoked' WHERE account_id=9910;").ok)
	assert(store.sell(99100,0,offer,"revoked").error=="stale_session" and state()==before)
	db.close()
	print("POSTGRES_VENDOR_SELL_OK partial/mixed/repeat, preview purity, replay/reopen, rollback/COMMIT unknown, full bag and session fencing")
	get_tree().quit()
