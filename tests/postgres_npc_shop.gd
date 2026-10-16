extends Node
## The existing NPC receipt/client journal suites remain on SQLite. This fixture
## compares the same economic use case on native PG with authoritative snapshots.
const Schema = preload("res://source/server/world/database/postgres/npc_shop_schema_postgres.gd")
const PgItems = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const PgShop = preload("res://source/server/world/database/postgres/npc_shop_store_postgres.gd")
const PgWallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const WATERMARK: int = 9007199254741033 # Above JSON's exact double integer range.
var sqlite: SQLite
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
	sqlite=SQLite.new()
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
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(sqlite.path+suffix))
	print("POSTGRES_NPC_SHOP_OK SQLite parity: atomic purchase, custody, pending funds, receipts, replay/reopen, footprint, rollback and reject growth")
	get_tree().quit()
