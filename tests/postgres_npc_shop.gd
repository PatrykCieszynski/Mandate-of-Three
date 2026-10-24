extends Node
## The existing NPC receipt/client journal suites remain on SqliteSoci. This fixture
## compares the same economic use case on native PG with authoritative snapshots.
const Schema = preload("res://source/server/world/database/postgres/npc_shop_schema_postgres.gd")
const PgItems = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const PgShop = preload("res://source/server/world/database/postgres/npc_shop_store_postgres.gd")
const PgWallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const WATERMARK: int = 9007199254741033 # Above JSON's exact double integer range.
var sqlite: SqliteSoci
var pg: Object
var buyer: int
var alternate: int
var stranger: int
var account: int
var connection: String
var shop: ShopDefinition

func sql(is_pg: bool, text: String) -> bool:
	return pg.execute(text).ok if is_pg else sqlite.query(text)

func begin(is_pg: bool) -> bool:
	return pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;")

func finish(is_pg: bool) -> bool:
	return pg.commit() if is_pg else sqlite.query("COMMIT;")

func undo(is_pg: bool) -> bool:
	return pg.rollback() if is_pg else sqlite.query("ROLLBACK;")

func capture(items: RefCounted, wallets: RefCounted, is_pg: bool) -> Dictionary:
	var inventory: Dictionary=items.inventory(buyer)
	var wallet: Dictionary=wallets.load_wallet(account)
	assert(inventory.ok and wallet.ok)
	var table: String="economy.market_commands" if is_pg else "market_commands"
	var count: int
	if is_pg:
		count=int(pg.query("SELECT COUNT(*) AS n FROM "+table+";").rows[0].n)
	else:
		assert(sqlite.query("SELECT COUNT(*) AS n FROM "+table+";"))
		count=int(sqlite.query_result[0].n)
	return {"inventory":inventory,"wallet":wallet,"receipts":count}

func canonical(snapshot: Dictionary) -> Dictionary:
	var result:=snapshot.duplicate(true)
	result.inventory.item_state.erase("authority_id")
	result.wallet.wallet_state.erase("authority_id")
	for item: Dictionary in result.inventory.items: item.erase("uid")
	return result

func inject_fault(is_pg: bool, stage: String) -> void:
	var table: String={"item":"item_custody","wallet":"account_wallets","receipt":"market_commands"}[stage]
	var event: String="UPDATE" if stage=="wallet" else "INSERT"
	if is_pg:
		assert(sql(is_pg,"CREATE OR REPLACE FUNCTION economy.fixture_npc_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'npc fixture fault'; END; $$;"))
		assert(sql(is_pg,"CREATE TRIGGER fixture_npc_fault BEFORE %s ON economy.%s FOR EACH ROW EXECUTE FUNCTION economy.fixture_npc_fault();" % [event,table]))
	else:
		assert(sql(is_pg,"CREATE TEMP TRIGGER fixture_npc_fault BEFORE %s ON %s BEGIN SELECT RAISE(ABORT,'npc fixture fault'); END;" % [event,table]))

func clear_fault(is_pg: bool, stage: String) -> void:
	var table: String={"item":"item_custody","wallet":"account_wallets","receipt":"market_commands"}[stage]
	assert(sql(is_pg,"DROP TRIGGER fixture_npc_fault ON economy.%s;" % table if is_pg else "DROP TRIGGER fixture_npc_fault;"))

func exercise(store: RefCounted, items: RefCounted, wallets: RefCounted, is_pg: bool) -> Array:
	var snapshots: Array=[]
	var before:=capture(items,wallets,is_pg)
	assert(store.purchase_receipt(buyer,"absent").error=="unknown_command")
	assert(store.purchase_receipt(999999,"absent").error=="owner")
	assert(store.purchase(buyer,0,shop,&"ore",-1,"").error=="request")
	assert(store.purchase(buyer,0,shop,&"missing",-1,"bad-offer").error=="unknown_offer")
	assert(store.purchase(buyer,0,shop,&"sword",40,"bad-edge").error=="request")
	assert(capture(items,wallets,is_pg)==before)
	var bought: Dictionary=store.purchase(buyer,30,shop,&"sword",10,"paid-sword")
	assert(bought.ok and bought.balance==1280 and bought.position==10)
	assert(bought.wallet_states[0].pending_applied==30)
	assert(bought.item_state.revision==WATERMARK+2 and bought.wallet_states[0].revision==WATERMARK+2)
	assert(items.inventory(buyer).items.size()==1)
	var uid: String=bought.uid
	before=capture(items,wallets,is_pg)
	# Lost response: exact target is occupied now. Receipt resolution precedes
	# placement/affordability, and must not reapply NEW pending income on replay.
	assert(store.purchase(buyer,999,shop,&"sword",10,"paid-sword")==bought)
	assert(store.purchase_receipt(buyer,"paid-sword")==bought)
	assert(capture(items,wallets,is_pg)==before)
	assert(store.purchase(buyer,0,shop,&"sword",11,"paid-sword").error=="command_conflict")
	assert(store.purchase(alternate,0,shop,&"sword",10,"paid-sword").error=="command_conflict")
	assert(store.purchase_receipt(alternate,"paid-sword").error=="unknown_command")
	assert(store.purchase_receipt(stranger,"paid-sword").error=="unknown_command")
	assert(store.purchase(buyer,0,shop,&"ore",15,"overlap").error=="occupied")
	assert(capture(items,wallets,is_pg)==before)
	snapshots.append(canonical(before))
	for stage: String in ["wallet","item","receipt"]:
		inject_fault(is_pg,stage)
		assert(store.purchase(buyer,17,shop,&"ore",-1,"fault-"+stage).error=="storage")
		assert(capture(items,wallets,is_pg)==before, "item, funds, pending income, revisions and receipt must all roll back")
		assert(store.purchase_receipt(buyer,"fault-"+stage).error=="unknown_command")
		clear_fault(is_pg,stage)
	var material: Dictionary=store.purchase(buyer,20,shop,&"ore",-1,"paid-ore")
	assert(material.ok and material.position==0 and material.balance==1200)
	var ore_found:=false
	for item: Dictionary in items.inventory(buyer).items:
		if item.uid==material.uid: ore_found=item.definition_id=="upgrade_ore" and item.amount==3
	assert(ore_found, "authoritative stack amount survives persistence")
	assert(wallets.spend(account,0,1199).ok)
	before=capture(items,wallets,is_pg)
	assert(store.purchase(buyer,0,shop,&"ore",-1,"no-funds").error=="funds")
	assert(capture(items,wallets,is_pg)==before)
	# No partial footprint across pages and no receipt rows for rejected spam.
	for index: int in 80:
		assert(store.purchase(buyer,0,shop,&"sword",-2,"reject-"+str(index)).error=="request")
	assert(capture(items,wallets,is_pg)==before)
	assert(before.receipts==2)
	snapshots.append(canonical(before))
	# Fill with single-cell material items, keeping all original UIDs unchanged.
	for index: int in InventoryGrid.CAPACITY:
		assert(begin(is_pg))
		var added: Dictionary=items.receive_item_in_transaction(ItemInstance.create(ItemDefinitions.UPGRADE_ORE,buyer,[]))
		if not added.ok:
			assert(added.error=="inventory_full" and undo(is_pg))
			break
		assert(finish(is_pg))
	before=capture(items,wallets,is_pg)
	inject_fault(is_pg,"wallet")
	assert(store.purchase(buyer,2000,shop,&"ore",-1,"full").error=="inventory_full", "capacity is checked before any wallet write")
	clear_fault(is_pg,"wallet")
	assert(capture(items,wallets,is_pg)==before)
	# Reopen and reconstruct a fresh store. Durable retry works even with a full
	# bag and insufficient funds, and publishes the ORIGINAL receipt watermarks.
	if is_pg:
		pg.close()
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
		store=PgShop.new(pg)
	else:
		assert(sqlite.close_db() and sqlite.open_db())
		store=ShopStoreSqlite.new(sqlite)
	assert(store.purchase(buyer,3000,shop,&"sword",10,"paid-sword")==bought)
	assert(store.purchase_receipt(buyer,"paid-sword").uid==uid)
	assert(capture(items,wallets,is_pg)==before)
	return snapshots

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	shop=ShopDefinition.new()
	shop.shop_id=&"pg_npc_fixture"
	shop.display_name="PG NPC fixture"
	for key: String in ["sword","ore"]:
		var offer:=ShopOfferDefinition.new()
		offer.offer_id=StringName(key)
		offer.item_definition_id=&"iron_sword" if key=="sword" else &"upgrade_ore"
		offer.price=250 if key=="sword" else 100
		offer.quantity=1 if key=="sword" else 3
		shop.offers.append(offer)
	assert(shop.validation_errors().is_empty())
	sqlite=SqliteSoci.new()
	sqlite.path=directory+"/npc-shop.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	buyer=EconomyFixture.create_character(identities,"pg-npc-a",{"name":"A","skin":1})
	alternate=EconomyFixture.create_character(identities,"pg-npc-a",{"name":"Alt","skin":1})
	stranger=EconomyFixture.create_character(identities,"pg-npc-b",{"name":"B","skin":1})
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	account=identities.resolve_account_id(buyer)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	var pg_wallet:=PgWallet.new(pg)
	var pg_items:=PgItems.new(pg)
	for character: int in [buyer,alternate,stranger]:
		var id:=identities.resolve_account_id(character)
		assert(pg_wallet.initialize_account(id).ok and pg_items.bind_character(character,id))
	assert(not pg_items.bind_character(buyer,identities.resolve_account_id(stranger)), "trusted mapping cannot silently change account")
	assert(Schema.ensure_schema(pg))
	# Controlled fixture seed: neither store may round high-water revisions through
	# JSON doubles. Seed via INSERT so the UPDATE revision triggers stay enabled.
	assert(sqlite.query_with_bindings("INSERT INTO account_item_revisions(account_name,revision) SELECT account_name,? FROM accounts WHERE master_account_id=?;",[WATERMARK,account]))
	assert(sqlite.query_with_bindings("DELETE FROM account_wallets WHERE account_id=?;",[account]))
	assert(sqlite.query_with_bindings("INSERT INTO account_wallets(account_id,yang,wallet_revision) VALUES(?,1500,?);",[account,WATERMARK]))
	assert(pg.execute("INSERT INTO economy.account_item_revisions VALUES(:account,:revision);",{"account":account,"revision":WATERMARK}).ok)
	assert(pg.execute("DELETE FROM economy.account_wallets WHERE account_id=:account;",{"account":account}).ok)
	assert(pg.execute("INSERT INTO economy.account_wallets(account_id,yang,wallet_revision) VALUES(:account,1500,:revision);",{"account":account,"revision":WATERMARK}).ok)
	var baseline:=exercise(ShopStoreSqlite.new(sqlite),ItemStoreSqlite.new(sqlite),WalletStoreSqlite.new(sqlite),false)
	var candidate:=exercise(PgShop.new(pg),pg_items,pg_wallet,true)
	assert(baseline==candidate, "economic snapshots match existing SQLite behavior")
	var store:=PgShop.new(pg)
	assert(pg.execute("INSERT INTO economy.market_commands(account_id,command_id,character_id,kind,request_json,result_json) VALUES(:account,'unrelated',:owner,'fixture','[]','{\"ok\":true}');",{"account":account,"owner":buyer}).ok)
	assert(store.purchase_receipt(buyer,"unrelated").error=="unknown_command", "read-only recovery cannot return another command kind")
	assert(store.purchase(buyer,0,shop,&"ore",-1,"unrelated").error=="command_conflict")
	var before:=capture(pg_items,pg_wallet,true)
	var before_alt:=pg_items.inventory(alternate)
	# PostgreSQL-only COMMIT fault, after wallet + item + receipt writes. Failure
	# remains unknown to the API; discard session, then inspect committed state.
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_npc_fault();").ok)
	var uncertain: Dictionary=store.purchase(alternate,1000,shop,&"ore",-1,"deferred-fault")
	assert(not uncertain.ok and uncertain.get("outcome_unknown",false) and not pg.is_open())
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	assert(pg.execute("DROP TRIGGER fixture_commit ON economy.market_commands;").ok)
	assert(capture(pg_items,pg_wallet,true)==before and pg_items.inventory(alternate)==before_alt)
	assert(store.purchase_receipt(alternate,"deferred-fault").error=="unknown_command")
	# Mutual deferred custody references must reject orphan rows at COMMIT.
	assert(pg.begin())
	assert(pg.execute("INSERT INTO economy.item_instances(uid,owner_character_id,definition_id,amount,affixes_json,sockets_json) VALUES(:uid,:owner,'upgrade_ore',1,'[]','[]');",{"uid":"a".repeat(32),"owner":alternate}).ok)
	assert(not pg.commit() and pg.rollback())
	assert(capture(pg_items,pg_wallet,true)==before and pg_items.inventory(alternate)==before_alt)
	assert(pg.begin())
	assert(pg.execute("INSERT INTO economy.item_instances(uid,owner_character_id,definition_id,amount,affixes_json,sockets_json) VALUES(:uid,:owner,'upgrade_ore',1,'[]','[]');",{"uid":"b".repeat(32),"owner":alternate}).ok)
	assert(pg.execute("INSERT INTO economy.item_custody VALUES(:uid,'equipment',:wrong_owner,-1,'weapon');",{"uid":"b".repeat(32),"wrong_owner":buyer}).ok)
	assert(not pg.commit() and pg.rollback(), "custody cannot name a different character than the item owner")
	assert(capture(pg_items,pg_wallet,true)==before and pg_items.inventory(alternate)==before_alt)
	assert(pg.begin())
	assert(pg_items.resolve_inventory_position(alternate,3,30).ok)
	assert(pg_items.resolve_inventory_position(alternate,3,35).error=="request")
	assert(pg.rollback())
	# PostgreSQL recovery filters an explicit BIGINT receiving character, avoiding
	# JSON-double rounding of request arguments for large IDs.
	var large_character: int=WATERMARK+100
	assert(pg_items.bind_character(large_character,identities.resolve_account_id(stranger)))
	var large_receipt: Dictionary=store.purchase(large_character,0,shop,&"ore",-1,"large-character")
	assert(large_receipt.ok and large_receipt.item_state.character_id==large_character)
	assert(store.purchase_receipt(large_character,"large-character")==large_receipt)
	assert(store.purchase(large_character,99,shop,&"ore",-1,"large-character")==large_receipt)
	await retry_checks(pg_items)
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(sqlite.path+suffix))
	print("POSTGRES_NPC_SHOP_OK SQLite parity: atomic purchase, custody, pending funds, receipts, replay/reopen, footprint, rollback and reject growth")
	get_tree().quit()

func retry_checks(items: RefCounted) -> void:
	assert(PgWallet.new(pg).initialize_account(8200).ok)
	assert(pg.execute("UPDATE economy.account_wallets SET yang=100000 WHERE account_id=8200;").ok)
	assert(pg.execute("CREATE SEQUENCE economy.fixture_purchase_attempt;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_purchase_retry() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE attempt BIGINT; BEGIN attempt:=nextval('economy.fixture_purchase_attempt'); IF attempt<=TG_ARGV[1]::BIGINT THEN IF TG_NARGS>2 THEN PERFORM pg_advisory_xact_lock(95128); END IF; RAISE EXCEPTION 'purchase retry fixture' USING ERRCODE=TG_ARGV[0]; END IF; RETURN NEW; END; $$;").ok)
	var store:=PgShop.new(pg)
	var index: int=0
	for stage: String in ["income","spend","instance","custody","receipt"]:
		for code: String in ["40001","40P01"]:
			for offer: ShopOfferDefinition in shop.offers:
				var character: int=82000+index
				assert(items.bind_character(character,8200))
				var balance: int=PgWallet.new(pg).load_wallet(8200).balance
				purchase_retry_fault(stage,code,1)
				var command: String="retry-purchase-"+str(index)
				var result: Dictionary=store.purchase(character,17,shop,offer.offer_id,0,command)
				assert(result.ok and store.committed and purchase_attempts()==2 and result.balance==balance+17-offer.price)
				assert(result.wallet_states[0].pending_applied==17 and PgWallet.new(pg).load_wallet(8200).balance==result.balance)
				var inventory: Array=items.inventory(character).items
				assert(inventory.size()==1 and inventory[0].uid==result.uid and inventory[0].definition_id==str(offer.item_definition_id) and inventory[0].amount==offer.quantity and inventory[0].bag_position==0,"one durable UID and correct quantity after rollback/retry")
				var before:=retry_state()
				assert(store.purchase(character,9999,shop,offer.offer_id,0,command)==result and not store.committed and retry_state()==before and purchase_attempts()==2)
				assert(store.purchase_receipt(character,command)==result)
				clear_purchase_retry(stage)
				index+=1
	var character: int=82900
	assert(items.bind_character(character,8200))
	for code: String in ["40001","40P01","23505","55P03","57014"]:
		purchase_retry_fault("receipt",code,99)
		var before:=retry_state()
		var result: Dictionary=store.purchase(character,17,shop,&"sword",0,"exhausted-"+code)
		assert(result.error=="storage" and not store.committed and not pg.in_transaction() and retry_state()==before)
		assert(purchase_attempts()==(3 if code in ["40001","40P01"] else 1))
		clear_purchase_retry("receipt")
	for code: String in ["40001","40P01"]:
		purchase_retry_fault("receipt",code,99,true)
		var before:=retry_state()
		var result: Dictionary=store.purchase(character,17,shop,&"sword",0,"unknown-"+code)
		assert(result.get("outcome_unknown",false) and not store.committed and not pg.is_open())
		assert(pg.open("postgresql",connection) and purchase_attempts()==1)
		clear_purchase_retry("receipt")
		assert(retry_state()==before and store.purchase_receipt(character,"unknown-"+code).error=="unknown_command")
	for requested: int in [0,-1]: await retry_capacity(items,requested)
	print("POSTGRES_NPC_PURCHASE_RETRY_OK one UID/debit/pending prefix, exact replay, bounded attempts, no COMMIT retry and current full-footprint placement")

func retry_state() -> Array:
	var snapshot: Array=[]
	for table: String in ["item_instances","item_custody","account_item_revisions","account_wallets","market_commands"]:
		var result: Dictionary=pg.query("SELECT row_to_json(t)::text AS value FROM economy."+table+" t ORDER BY row_to_json(t)::text;",{},10000)
		assert(result.ok and not result.truncated)
		snapshot.append(result.rows)
	return snapshot

func purchase_retry_table(stage: String) -> String:
	return {"income":"account_wallets","spend":"account_wallets","instance":"item_instances","custody":"item_custody","receipt":"market_commands"}[stage]

func purchase_retry_fault(stage: String, code: String, failures: int, deferred: bool = false) -> void:
	assert(pg.execute("ALTER SEQUENCE economy.fixture_purchase_attempt RESTART WITH 1;").ok)
	var table: String=purchase_retry_table(stage)
	var condition: String=" WHEN (NEW.yang>OLD.yang)" if stage=="income" else (" WHEN (NEW.yang<OLD.yang)" if stage=="spend" else "")
	var create: String="CREATE CONSTRAINT TRIGGER fixture_retry AFTER INSERT ON economy.%s DEFERRABLE INITIALLY DEFERRED" % table if deferred else "CREATE TRIGGER fixture_retry BEFORE %s ON economy.%s" % ["UPDATE" if stage in ["income","spend"] else "INSERT",table]
	assert(pg.execute(create+" FOR EACH ROW"+condition+" EXECUTE FUNCTION economy.fixture_purchase_retry('%s','%d');" % [code,failures]).ok)

func clear_purchase_retry(stage: String) -> void:
	assert(pg.execute("DROP TRIGGER fixture_retry ON economy."+purchase_retry_table(stage)+";").ok)

func purchase_attempts() -> int:
	return int(pg.query("SELECT last_value FROM economy.fixture_purchase_attempt;").rows[0].last_value)

func retry_capacity(items: RefCounted, requested: int) -> void:
	var character: int=82910 if requested==0 else 82911
	assert(items.bind_character(character,8200))
	var balance: int=PgWallet.new(pg).load_wallet(8200).balance
	assert(pg.execute("ALTER SEQUENCE economy.fixture_purchase_attempt RESTART WITH 1;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_retry BEFORE INSERT ON economy.market_commands FOR EACH ROW WHEN (current_setting('application_name')='retry-npc-buyer') EXECUTE FUNCTION economy.fixture_purchase_retry('40001','1','gate');").ok)
	assert(pg.execute("SELECT pg_advisory_lock(95128);").ok)
	# Coordinate independent sessions without changing normal fixture timeouts.
	var budgets: String=" options='-c statement_timeout=10000 -c lock_timeout=8000 -c idle_in_transaction_session_timeout=10000'"
	var ready:=Semaphore.new()
	var original: ShopDefinition=shop.duplicate(true)
	var buyer_thread:=Thread.new()
	assert(buyer_thread.start(purchase_worker.bind(connection+" application_name=retry-npc-buyer"+budgets,character,original,&"sword",requested,17,"capacity-buyer-"+str(character),ready))==OK)
	ready.wait()
	var buying: bool=await purchase_waiting("retry-npc-buyer")
	var editor:=Thread.new()
	# Occupy the last cell of the sword footprint, leaving its starting cell free.
	var blocked: int=InventoryGrid.cells(0,ItemDefinitions.IRON_SWORD.inventory_height).back()
	var occupied: Dictionary=items.inventory(character)
	assert(occupied.items.is_empty(),"other native transaction cannot see the uncommitted item")
	assert(editor.start(purchase_worker.bind(connection+" application_name=retry-npc-editor"+budgets,character,original,&"ore",blocked,0,"capacity-editor-"+str(character),ready))==OK)
	ready.wait()
	var editing: bool=await purchase_waiting("retry-npc-editor")
	# Both calls already captured accepted server offers before blocking. Resource
	# changes must not alter either the retried price or nested offer quantity.
	original.offers[0].price+=10000
	original.offers[1].quantity+=1
	assert(pg.execute("SELECT pg_advisory_unlock(95128);").ok)
	var bought: Dictionary=buyer_thread.wait_to_finish()
	var edited: Dictionary=editor.wait_to_finish()
	clear_purchase_retry("receipt")
	assert(buying and editing and edited.result.ok and edited.result.position==blocked)
	var inventory: Array=items.inventory(character).items
	assert(inventory.any(func(item: Dictionary) -> bool: return item.uid==edited.result.uid and item.amount==shop.offers[1].quantity))
	if requested==0:
		assert(bought.result.error=="occupied" and not bought.committed and purchase_attempts()==1)
		assert(inventory.size()==1 and PgWallet.new(pg).load_wallet(8200).balance==balance-shop.offers[1].price)
		assert(PgShop.new(pg).purchase_receipt(character,"capacity-buyer-"+str(character)).error=="unknown_command")
	else:
		assert(bought.result.ok and bought.committed and purchase_attempts()==2 and bought.result.position!=0)
		assert(inventory.size()==2 and PgWallet.new(pg).load_wallet(8200).balance==balance-shop.offers[1].price-shop.offers[0].price+17)
		var footprint:=InventoryGrid.cells(int(bought.result.position),ItemDefinitions.IRON_SWORD.inventory_height)
		assert(not footprint.has(blocked))
		assert(PgShop.new(pg).purchase(character,9999,shop,&"sword",requested,"capacity-buyer-"+str(character))==bought.result)

func purchase_waiting(label: String) -> bool:
	var deadline: int=Time.get_ticks_msec()+2000
	while Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		if int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)==1: return true
		await get_tree().create_timer(0.005).timeout
	return false

func purchase_worker(dsn: String, character: int, accepted: ShopDefinition, offer: StringName, position: int, pending: int, command: String, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"result":{"ok":false,"error":"fixture_connection"},"committed":false}
	var store:=PgShop.new(database)
	var result: Dictionary=store.purchase(character,pending,accepted,offer,position,command)
	var committed: bool=store.committed
	database.close()
	return {"result":result,"committed":committed}
