extends Node
## One conversion guarantee: Item stack <-> account fungible balance, with
## original operation replay, Storage ownership and real native conflicts.
const Schema = preload("res://source/server/world/database/postgres/exchange_ledger_schema_postgres.gd")
const Prior = preload("res://source/server/world/database/postgres/auction_search_schema_postgres.gd")
const Ledger = preload("res://source/server/world/database/postgres/exchange_ledger_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Storage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
const Claims = preload("res://source/server/world/database/postgres/account_claim_postgres.gd")
const Views = preload("res://source/server/world/database/postgres/shop_queries_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var pg: Object
var sqlite: SqliteSoci
var connection: String
var primary: int
var alt: int
var foreign: int
var account: int

func uid(id: int) -> String: return str(id).pad_zeros(32)

func execute(native: bool, sql: String) -> void:
	if native:
		var result: Dictionary=pg.execute(sql)
		assert(result.ok,str(result))
	else: assert(sqlite.query(sql))

func rows(native: bool, sql: String) -> Array:
	if native:
		var result: Dictionary=pg.query(sql)
		assert(result.ok and not result.truncated)
		return result.rows
	assert(sqlite.query(sql))
	return sqlite.query_result.duplicate(true)

func seed_item(items: RefCounted, native: bool, character: int, id: int, position: int, amount: int = 100, definition: ItemDefinition = ItemDefinitions.UPGRADE_ORE, rolls: Array = []) -> void:
	var item:=ItemInstance.create(definition,character,rolls)
	item.uid=uid(id)
	item.amount=amount
	assert(pg.begin() if native else sqlite.query("BEGIN IMMEDIATE;"))
	assert(items.receive_item_in_transaction(item,position).ok)
	assert(pg.commit() if native else sqlite.query("COMMIT;"))

func normalize(result: Dictionary) -> Dictionary:
	var copy:=result.duplicate(true)
	if copy.has("amount"): copy.amount=int(copy.amount)
	if copy.has("position"): copy.position=int(copy.position)
	if copy.has("item_state"): copy.item_state.erase("authority_id")
	return copy

func capture(ledger: RefCounted, items: RefCounted, storage: RefCounted, views: RefCounted, native: bool) -> Dictionary:
	var inventories: Array=[]
	for character: int in [primary,alt,foreign]:
		var inventory: Dictionary=items.inventory(character)
		inventory.item_state.erase("authority_id")
		inventory.items.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return a.bag_position<b.bag_position)
		inventories.append(inventory)
	var claims: Array=views.mine(primary).claims
	var prefix: String="economy." if native else ""
	return {"ledger":ledger.ledger(primary),"alt":ledger.ledger(alt),"foreign":ledger.ledger(foreign),"inventories":inventories,"storage":storage.snapshot(primary),"claims":claims,"receipts":int(rows(native,"SELECT COUNT(*) AS n FROM "+prefix+"market_commands;")[0].n),"affixes":rows(native,"SELECT uid,ordinal,stat_id,value FROM "+prefix+"item_affix_index ORDER BY uid,ordinal;")}

func canonical(snapshot: Dictionary, generated: Array) -> Dictionary:
	# Only generated withdrawal IDs differ between backends. Keep all original
	# fixture UIDs/provenance/revisions and account watermarks for comparison.
	var result:=snapshot.duplicate(true)
	for inventory: Dictionary in result.inventories:
		for item: Dictionary in inventory.items:
			var index: int=generated.find(item.uid)
			if index>=0: item.uid="withdraw-"+str(index)
	for item: Dictionary in result.storage.items:
		var index: int=generated.find(item.uid)
		if index>=0: item.uid="withdraw-"+str(index)
	for item: Dictionary in result.claims:
		var index: int=generated.find(item.uid)
		if index>=0: item.uid="withdraw-"+str(index)
	return result

func fault(native: bool, table: String, event: String) -> void:
	if native:
		execute(true,"CREATE OR REPLACE FUNCTION economy.fixture_ledger_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'ledger fixture fault'; END; $$;")
		execute(true,"CREATE TRIGGER fixture_ledger_fault BEFORE %s ON economy.%s FOR EACH ROW EXECUTE FUNCTION economy.fixture_ledger_fault();" % [event,table])
	else: execute(false,"CREATE TEMP TRIGGER fixture_ledger_fault BEFORE %s ON %s BEGIN SELECT RAISE(ABORT,'ledger fixture fault'); END;" % [event,table])

func clear_fault(native: bool, table: String) -> void:
	execute(native,"DROP TRIGGER fixture_ledger_fault ON economy."+table+";" if native else "DROP TRIGGER fixture_ledger_fault;")

func exercise(ledger: RefCounted, items: RefCounted, storage: RefCounted, claims: RefCounted, views: RefCounted, native: bool) -> Array:
	var checkpoints: Array=[]
	var generated: Array=[]
	var prefix: String="economy." if native else ""
	assert(ledger.ledger(primary)==ledger.ledger(alt) and ledger.ledger(primary).assets.size()==5)
	assert(ledger.ledger(999999).error=="owner")
	seed_item(items,native,primary,1,0)
	assert(ledger.deposit(foreign,"foreign",uid(1),0,100,"bag").error=="owner")
	assert(ledger.deposit(alt,"alt-bag",uid(1),0,100,"bag").error=="owner")
	assert(ledger.deposit(primary,"wrong-source",uid(1),0,100,"account_storage").error=="owner")
	assert(ledger.deposit(primary,"stale",uid(1),1,100,"bag").error=="stale")
	assert(ledger.deposit(primary,"too-many",uid(1),0,101,"bag").error=="not_fungible")
	var before:=capture(ledger,items,storage,views,native)
	for stage: Array in [["exchange_assets","INSERT"],["item_custody","DELETE"],["item_instances","DELETE"],["market_commands","INSERT"]]:
		fault(native,stage[0],stage[1])
		assert(ledger.deposit(primary,"deposit",uid(1),0,100,"bag").error=="storage")
		assert(capture(ledger,items,storage,views,native)==before)
		clear_fault(native,stage[0])
	var deposited: Dictionary=ledger.deposit(primary,"deposit",uid(1),0,100,"bag")
	assert(deposited.ok and ledger.committed)
	assert(normalize(ledger.deposit(primary,"deposit",uid(1),0,100,"bag"))==normalize(deposited) and not ledger.committed)
	assert(ledger.deposit(alt,"deposit",uid(1),0,100,"bag").error=="command_conflict")
	before=capture(ledger,items,storage,views,native)
	for destination: String in ["bag","claim"]:
		for stage: Array in [["exchange_assets","UPDATE"],["item_instances","INSERT"],["item_custody","INSERT"],["market_commands","INSERT"]]:
			fault(native,stage[0],stage[1])
			assert(ledger.withdraw(alt,"withdraw-"+destination,"upgrade_ore",35,destination).error=="storage")
			assert(capture(ledger,items,storage,views,native)==before)
			clear_fault(native,stage[0])
	var paid: Dictionary=ledger.withdraw(alt,"withdraw-bag","upgrade_ore",35,"bag")
	assert(paid.ok and ledger.committed and ItemInstance.valid_uid(paid.uid))
	generated.append(paid.uid)
	assert(normalize(ledger.withdraw(alt,"withdraw-bag","upgrade_ore",35,"bag"))==normalize(paid) and not ledger.committed)
	assert(normalize(ledger.receipt(primary,"withdraw-bag"))==normalize(paid))
	assert(ledger.receipt(foreign,"withdraw-bag").error=="unknown_command")
	assert(ledger.withdraw(primary,"withdraw-bag","upgrade_ore",35,"bag").error=="command_conflict")
	assert(storage.transfer_command(alt,paid.uid,0,"inventory","storage",0,"store").ok)
	assert(ledger.deposit(foreign,"foreign-storage",paid.uid,1,1,"account_storage").error=="owner")
	# Cross-alt Storage consumption uses account ownership, not provenance.
	assert(ledger.deposit(primary,"partial",paid.uid,1,10,"account_storage").ok)
	assert(storage.snapshot(primary).items[0].amount==25 and storage.snapshot(primary).items[0].revision==2)
	assert(ledger.deposit(primary,"stale-stored",paid.uid,1,10,"account_storage").error=="stale")
	before=capture(ledger,items,storage,views,native)
	fault(native,"item_instances","UPDATE")
	assert(ledger.deposit(primary,"partial-fault",paid.uid,2,1,"account_storage").error=="storage")
	assert(capture(ledger,items,storage,views,native)==before)
	clear_fault(native,"item_instances")
	before=capture(ledger,items,storage,views,native)
	for stage: Array in [["item_custody","DELETE"],["item_instances","DELETE"],["market_commands","INSERT"]]:
		fault(native,stage[0],stage[1])
		assert(ledger.deposit(primary,"consume-stored",paid.uid,2,25,"account_storage").error=="storage")
		assert(capture(ledger,items,storage,views,native)==before)
		clear_fault(native,stage[0])
	assert(ledger.deposit(primary,"consume-stored",paid.uid,2,25,"account_storage").ok)
	assert(storage.snapshot(alt).items.is_empty())
	# All 100 ore are back in the ledger. Reserved units remain unwithdrawable.
	execute(native,"UPDATE "+prefix+"exchange_assets SET free=40,reserved=60 WHERE account_id="+str(account)+" AND asset_id='upgrade_ore';")
	assert(ledger.withdraw(alt,"reserved","upgrade_ore",41,"bag").error=="funds")
	paid=ledger.withdraw(primary,"claim","upgrade_ore",20,"claim")
	assert(paid.ok)
	generated.append(paid.uid)
	assert(views.mine(alt).claims[0].amount==20)
	assert(ledger.deposit(primary,"claim-source",paid.uid,0,1,"bag").error=="owner")
	assert(claims.claim_item(alt,"receive",paid.uid,0).ok)
	assert(views.mine(primary).claims.is_empty())
	checkpoints.append(canonical(capture(ledger,items,storage,views,native),generated))
	# Metadata-bearing stacks are never converted to fungible balances.
	seed_item(items,native,primary,2,0,1,ItemDefinitions.UPGRADE_ORE,[{"stat":"attack","value":1}])
	assert(ledger.deposit(primary,"affixed",uid(2),0,1,"bag").error=="not_fungible")
	seed_item(items,native,primary,3,1,1)
	execute(native,"UPDATE "+prefix+"item_instances SET sockets_json='[1]' WHERE uid='"+uid(3)+"';")
	assert(ledger.deposit(primary,"socketed",uid(3),0,1,"bag").error=="not_fungible")
	execute(native,"UPDATE "+prefix+"item_instances SET sockets_json='[]',upgrade_level=1 WHERE uid='"+uid(3)+"';")
	assert(ledger.deposit(primary,"upgraded",uid(3),0,1,"bag").error=="not_fungible")
	seed_item(items,native,primary,4,30,1,ItemDefinitions.IRON_SWORD)
	assert(ledger.deposit(primary,"weapon",uid(4),0,1,"bag").error=="not_fungible")
	assert(ledger.withdraw(primary,"bad-asset","iron_sword",1,"bag").error=="request")
	assert(ledger.withdraw(primary,"bad-dest","upgrade_ore",1,"account_storage").error=="request")
	# Every canonical fungible material is visible and uses the same conversion.
	var materials: Array[ItemDefinition]=[ItemDefinitions.FOREST_RESIN,ItemDefinitions.BEAST_HIDE,ItemDefinitions.WOLF_FANG,ItemDefinitions.BANDIT_TOKEN]
	for index: int in materials.size():
		var definition: ItemDefinition=materials[index]
		var asset: String=str(definition.definition_id)
		seed_item(items,native,primary,10+index,5+index,3,definition)
		assert(ledger.deposit(primary,"material-"+asset,uid(10+index),0,3,"bag").ok)
		paid=ledger.withdraw(alt,"payout-"+asset,asset,2,"bag")
		assert(paid.ok)
		generated.append(paid.uid)
	# A full bag rolls the debit back; explicit claim destination still works.
	var occupied: Dictionary={}
	for item: Dictionary in items.inventory(alt).items: occupied[int(item.bag_position)]=true
	for position: int in 180:
		if not occupied.has(position): seed_item(items,native,alt,1000+position,position,1)
	before=capture(ledger,items,storage,views,native)
	assert(ledger.withdraw(alt,"full-bag","upgrade_ore",1,"bag").error=="inventory_full")
	assert(capture(ledger,items,storage,views,native)==before)
	paid=ledger.withdraw(alt,"explicit-claim","upgrade_ore",1,"claim")
	assert(paid.ok)
	generated.append(paid.uid)
	# Cap includes reserved units; overflow rolls back rather than losing a stack.
	seed_item(items,native,primary,20,20,1)
	execute(native,"UPDATE "+prefix+"exchange_assets SET free=8999999999999940,reserved=60 WHERE account_id="+str(account)+" AND asset_id='upgrade_ore';")
	before=capture(ledger,items,storage,views,native)
	assert(ledger.deposit(primary,"overflow",uid(20),0,1,"bag").error=="storage")
	assert(capture(ledger,items,storage,views,native)==before)
	checkpoints.append(canonical(before,generated))
	if native:
		pg.close()
		assert(pg.open("postgresql",connection))
	else:
		sqlite.close_db()
		assert(sqlite.open_db())
	assert(normalize(ledger.withdraw(alt,"explicit-claim","upgrade_ore",1,"claim"))==normalize(paid))
	assert(capture(ledger,items,storage,views,native)==before)
	return checkpoints

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	sqlite=SqliteSoci.new()
	sqlite.path=directory+"/exchange-ledger.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	primary=EconomyFixture.create_character(identities,"ledger",{"name":"Ledger","skin":1})
	alt=EconomyFixture.create_character(identities,"ledger",{"name":"Alt","skin":1})
	foreign=EconomyFixture.create_character(identities,"other",{"name":"Other","skin":1})
	account=identities.resolve_account_id(primary)
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Prior.ensure_schema(pg))
	var items:=Items.new(pg)
	for character: int in [primary,alt,foreign]:
		var identity: int=identities.resolve_account_id(character)
		assert(Wallet.new(pg).initialize_account(identity).ok and items.bind_character(character,identity))
	seed_item(items,true,foreign,99,0)
	var prior:=items.inventory(foreign)
	execute(true,"CREATE FUNCTION economy.fixture_ledger_schema_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.feature='exchange_ledger' THEN RAISE EXCEPTION 'ledger schema fault'; END IF; RETURN NEW; END; $$;")
	execute(true,"CREATE TRIGGER fixture_ledger_schema_fault BEFORE INSERT ON economy.schema_versions FOR EACH ROW EXECUTE FUNCTION economy.fixture_ledger_schema_fault();")
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction() and items.inventory(foreign)==prior)
	assert(pg.query("SELECT to_regclass('economy.exchange_assets')::text AS name;").rows[0].name==null)
	execute(true,"DROP TRIGGER fixture_ledger_schema_fault ON economy.schema_versions;")
	assert(Schema.ensure_schema(pg) and Schema.ensure_schema(pg) and items.inventory(foreign)==prior)
	seed_item(ItemStoreSqlite.new(sqlite),false,foreign,99,0)
	var market:=MarketStoreSqlite.new(sqlite)
	var baseline:=exercise(ExchangeStoreSqlite.new(sqlite),ItemStoreSqlite.new(sqlite),AccountStorageSqlite.new(sqlite),market,market,false)
	var candidate:=exercise(Ledger.new(pg),items,Storage.new(pg),Claims.new(pg),Views.new(pg),true)
	assert(baseline==candidate,"ledger, stack/claim/Storage custody, revisions and receipts match SQLite")
	await native_checks(items)
	await retry_checks(items)
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	print("POSTGRES_EXCHANGE_LEDGER_OK stack conversion parity, Storage/claim ownership, rollback/replay/reopen and independent native conflicts")
	get_tree().quit()

func native_state() -> Array:
	var result: Array=[]
	for table: String in ["exchange_assets","item_instances","item_custody","market_commands","account_item_revisions","item_affix_index"]:
		result.append(rows(true,"SELECT row_to_json(t)::text AS value FROM economy."+table+" t ORDER BY row_to_json(t)::text;"))
	return result

func native_checks(items: RefCounted) -> void:
	assert(Wallet.new(pg).initialize_account(7000).ok)
	for character: int in [70000,70001]: assert(items.bind_character(character,7000))
	var ledger:=Ledger.new(pg)
	var storage:=Storage.new(pg)
	seed_item(items,true,70000,9001,0,20)
	assert(storage.transfer_command(70000,uid(9001),0,"inventory","storage",0,"native-store").ok)
	var results:=await race([[70000,"deposit-a","deposit",[uid(9001),1,15,"account_storage"]],[70001,"deposit-b","deposit",[uid(9001),1,15,"account_storage"]]],"deposit-race")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1)
	assert(ledger.ledger(70000).assets[0].free==15 and storage.snapshot(70001).items[0].amount==5)
	results=await race([[70000,"withdraw-a","withdraw",["upgrade_ore",10,"bag"]],[70001,"withdraw-b","withdraw",["upgrade_ore",10,"bag"]]],"withdraw-race")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1 and ledger.ledger(70001).assets[0].free==5)
	results=await race([[70001,"same-withdraw","withdraw",["upgrade_ore",5,"claim"]],[70001,"same-withdraw","withdraw",["upgrade_ore",5,"claim"]]],"withdraw-replay")
	assert(results[0].result.ok and results[0].result==results[1].result and int(results[0].committed)+int(results[1].committed)==1)
	assert(Views.new(pg).mine(70000).claims.size()==1 and ledger.ledger(70000).assets[0].free==0)
	# Compete with the existing Storage withdrawal path for the same whole UID.
	seed_item(items,true,70000,9003,30,20)
	assert(storage.transfer_command(70000,uid(9003),0,"inventory","storage",10,"store-race").ok)
	results=await race([[70000,"consume-all","deposit",[uid(9003),1,20,"account_storage"]],[70001,"take-stored","storage",[uid(9003),1,20]]],"consume-transfer")
	assert(int(results[0].result.ok)+int(results[1].result.ok)==1)
	var balance: int=ledger.ledger(70000).assets[0].free
	var received: bool=items.inventory(70001).items.any(func(i: Dictionary) -> bool: return i.uid==uid(9003) and i.amount==20)
	assert((balance==20 and not received) or (balance==0 and received),"one stack becomes ledger OR receiving Inventory, never both")
	seed_item(items,true,70000,9002,20,20)
	for action: String in ["deposit","withdraw"]:
		var before:=native_state()
		execute(true,"CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_ledger_fault();")
		var result: Dictionary=ledger.deposit(70000,"commit-deposit",uid(9002),0,20,"bag") if action=="deposit" else ledger.withdraw(70001,"commit-withdraw","upgrade_ore",5,"claim")
		assert(result.get("outcome_unknown",false) and not pg.is_open() and not ledger.committed)
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
		execute(true,"DROP TRIGGER fixture_commit ON economy.market_commands;")
		assert(native_state()==before and ledger.receipt(70000,"commit-"+action).error=="unknown_command")
		if action=="withdraw": assert(ledger.withdraw(70001,"commit-withdraw","upgrade_ore",5,"claim").ok)
		else: assert(ledger.deposit(70000,"commit-deposit",uid(9002),0,20,"bag").ok)
	assert(pg.begin())
	assert(ledger.withdraw(70000,"nested","upgrade_ore",1,"claim").error=="storage" and ledger.ledger(70000).error=="storage" and pg.in_transaction() and pg.rollback())
	assert(Storage.new(pg).consume_in_transaction(70000,uid(9001),2,1).error=="transaction")
	assert(Claims.new(pg).receive_in_transaction(ItemInstance.create(ItemDefinitions.UPGRADE_ORE,70000,[])).error=="transaction")
	execute(true,"UPDATE economy.schema_versions SET version=999 WHERE feature='exchange_ledger';")
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	execute(true,"UPDATE economy.schema_versions SET version=1 WHERE feature='exchange_ledger';")
	assert(Schema.ensure_schema(pg))
	print("POSTGRES_EXCHANGE_LEDGER_NATIVE_OK shared Storage deposit, no overspend, one withdrawal UID, COMMIT unknown and transaction ownership")

func race(specs: Array, label: String) -> Array:
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=7000 FOR UPDATE;").ok)
	var ready:=Semaphore.new()
	var workers: Array[Thread]=[]
	for spec: Array in specs:
		var worker:=Thread.new()
		assert(worker.start(race_worker.bind(connection+" application_name="+label,spec,ready))==OK)
		workers.append(worker)
	for index: int in 2: ready.wait()
	var waiting: int=0
	var deadline: int=Time.get_ticks_msec()+500
	while waiting<2 and Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		waiting=int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)
		if waiting<2: await get_tree().create_timer(0.005).timeout
	assert(pg.commit())
	var results: Array=[]
	for worker: Thread in workers: results.append(worker.wait_to_finish())
	assert(waiting==2,"both worker-owned native sessions overlap")
	return results

func race_worker(dsn: String, spec: Array, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"result":{"ok":false,"error":"fixture_connection"},"committed":false}
	var ledger: RefCounted=Storage.new(database) if spec[2]=="storage" else Ledger.new(database)
	var args: Array=spec[3]
	var result: Dictionary
	match spec[2]:
		"storage": result=ledger.transfer_command(spec[0],args[0],args[1],"storage","inventory",args[2],spec[1])
		"deposit": result=ledger.deposit(spec[0],spec[1],args[0],args[1],args[2],args[3])
		_: result=ledger.withdraw(spec[0],spec[1],args[0],args[1],args[2])
	var committed: bool=ledger.committed
	database.close()
	return {"result":result,"committed":committed}

func retry_checks(items: RefCounted) -> void:
	assert(Wallet.new(pg).initialize_account(8000).ok)
	for character: int in [80000,80001]: assert(items.bind_character(character,8000))
	var ledger:=Ledger.new(pg)
	var storage:=Storage.new(pg)
	execute(true,"CREATE SEQUENCE economy.fixture_conversion_attempt;")
	execute(true,"CREATE FUNCTION economy.fixture_conversion_retry() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE attempt BIGINT; BEGIN attempt:=nextval('economy.fixture_conversion_attempt'); IF attempt<=TG_ARGV[1]::BIGINT THEN IF TG_NARGS>2 THEN PERFORM pg_advisory_xact_lock(95126); END IF; RAISE EXCEPTION 'conversion retry fixture' USING ERRCODE=TG_ARGV[0]; END IF; IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW; END; $$;")
	var index: int=0
	for source: String in ["bag","account_storage"]:
		for whole: bool in [false,true]:
			for code: String in ["40001","40P01"]:
				var id: int=9100+index
				seed_item(items,true,80000,id,index,20)
				var revision: int=0
				var character: int=80000
				if source=="account_storage":
					assert(storage.transfer_command(80000,uid(id),0,"inventory","storage",index,"retry-store-"+str(index)).ok)
					revision=1
					character=80001 # Shared account, original stack provenance retained.
				var amount: int=20 if whole else 7
				var before: int=retry_balance()
				# Partial mutation fails after ledger credit; whole deletion fails at
				# the receipt after custody and instance removal.
				var table: String="market_commands" if whole else "item_instances"
				conversion_fault(table,"INSERT" if whole else "UPDATE",code,1)
				var command: String="retry-deposit-"+str(index)
				var result: Dictionary=ledger.deposit(character,command,uid(id),revision,amount,source)
				assert(result.ok and ledger.committed and conversion_attempts()==2 and retry_balance()==before+amount)
				var stack: Array=rows(true,"SELECT amount,revision,owner_character_id FROM economy.item_instances WHERE uid='"+uid(id)+"';")
				if whole: assert(stack.is_empty())
				else: assert(stack.size()==1 and int(stack[0].amount)==13 and int(stack[0].revision)==revision+1 and int(stack[0].owner_character_id)==80000)
				var state:=native_state()
				assert(ledger.deposit(character,command,uid(id),revision,amount,source)==result and not ledger.committed and native_state()==state and conversion_attempts()==2)
				clear_conversion_fault(table)
				index+=1
	for destination: String in ["bag","claim"]:
		for table: String in ["item_custody","market_commands"]:
			for code: String in ["40001","40P01"]:
				conversion_fault(table,"INSERT",code,1)
				var before: int=retry_balance()
				var count: int=int(rows(true,"SELECT COUNT(*) AS n FROM economy.item_instances;")[0].n)
				var command: String="retry-withdraw-"+str(index)
				var result: Dictionary=ledger.withdraw(80001,command,"upgrade_ore",1,destination)
				assert(result.ok and ledger.committed and conversion_attempts()==2 and retry_balance()==before-1)
				assert(int(rows(true,"SELECT COUNT(*) AS n FROM economy.item_instances;")[0].n)==count+1,"aborted generated UID cannot survive withdrawal retry")
				var placement: Dictionary=rows(true,"SELECT i.amount,i.owner_character_id,c.location,c.claim_account_id FROM economy.item_instances i JOIN economy.item_custody c USING(uid) WHERE i.uid='"+result.uid+"';")[0]
				assert(int(placement.amount)==1 and int(placement.owner_character_id)==80001 and placement.location==("bag" if destination=="bag" else "account_claim"))
				if destination=="claim": assert(int(placement.claim_account_id)==8000)
				var state:=native_state()
				assert(ledger.withdraw(80001,command,"upgrade_ore",1,destination)==result and not ledger.committed and native_state()==state and conversion_attempts()==2)
				assert(ledger.receipt(80001,command)==result)
				clear_conversion_fault(table)
				index+=1
	seed_item(items,true,80000,9900,30,20)
	for code: String in ["40001","40P01","23505","55P03","57014"]:
		for deposit: bool in [true,false]:
			conversion_fault("market_commands","INSERT",code,99)
			var before:=native_state()
			var result: Dictionary=ledger.deposit(80000,"budget-deposit-"+code,uid(9900),0,1,"bag") if deposit else ledger.withdraw(80001,"budget-withdraw-"+code,"upgrade_ore",1,"claim")
			assert(result.error=="storage" and not ledger.committed and not pg.in_transaction() and native_state()==before)
			assert(conversion_attempts()==(3 if code in ["40001","40P01"] else 1))
			clear_conversion_fault("market_commands")
	for code: String in ["40001","40P01"]:
		for deposit: bool in [true,false]:
			conversion_fault("market_commands","INSERT",code,99,true)
			var before:=native_state()
			var command: String="commit-retry-"+code+str(deposit)
			var result: Dictionary=ledger.deposit(80000,command,uid(9900),0,1,"bag") if deposit else ledger.withdraw(80000,command,"upgrade_ore",1,"claim")
			assert(result.get("outcome_unknown",false) and not ledger.committed and not pg.is_open())
			assert(pg.open("postgresql",connection) and conversion_attempts()==1)
			clear_conversion_fault("market_commands")
			assert(native_state()==before and ledger.receipt(80000,command).error=="unknown_command")
	await retry_storage_reselection(items)
	print("POSTGRES_EXCHANGE_CONVERSION_RETRY_OK whole/partial bag/Storage conversion, unique withdrawal UID, replay, bounded attempts, no COMMIT retry and Storage reauthorization")

func retry_balance() -> int:
	var balances:=rows(true,"SELECT free FROM economy.exchange_assets WHERE account_id=8000 AND asset_id='upgrade_ore';")
	return 0 if balances.is_empty() else int(balances[0].free)

func conversion_fault(table: String, event: String, code: String, failures: int, deferred: bool = false) -> void:
	execute(true,"ALTER SEQUENCE economy.fixture_conversion_attempt RESTART WITH 1;")
	var create: String="CREATE CONSTRAINT TRIGGER fixture_retry AFTER INSERT ON economy.%s DEFERRABLE INITIALLY DEFERRED" % table if deferred else "CREATE TRIGGER fixture_retry BEFORE %s ON economy.%s" % [event,table]
	execute(true,create+" FOR EACH ROW EXECUTE FUNCTION economy.fixture_conversion_retry('%s','%d');" % [code,failures])

func clear_conversion_fault(table: String) -> void:
	execute(true,"DROP TRIGGER fixture_retry ON economy."+table+";")

func conversion_attempts() -> int:
	return int(rows(true,"SELECT last_value FROM economy.fixture_conversion_attempt;")[0].last_value)

func retry_storage_reselection(items: RefCounted) -> void:
	seed_item(items,true,80000,9901,31,20)
	assert(Storage.new(pg).transfer_command(80000,uid(9901),0,"inventory","storage",30,"retry-reselect-store").ok)
	var balance: int=retry_balance()
	execute(true,"ALTER SEQUENCE economy.fixture_conversion_attempt RESTART WITH 1;")
	execute(true,"CREATE TRIGGER fixture_retry BEFORE INSERT ON economy.market_commands FOR EACH ROW WHEN (current_setting('application_name')='retry-converter') EXECUTE FUNCTION economy.fixture_conversion_retry('40001','1','gate');")
	execute(true,"SELECT pg_advisory_lock(95126);")
	# Session-local coordination only; default fixture limits stay unchanged.
	var budgets: String=" options='-c statement_timeout=10000 -c lock_timeout=8000 -c idle_in_transaction_session_timeout=10000'"
	var ready:=Semaphore.new()
	var converter:=Thread.new()
	assert(converter.start(race_worker.bind(connection+" application_name=retry-converter"+budgets,[80001,"reselect-deposit","deposit",[uid(9901),1,20,"account_storage"]],ready))==OK)
	ready.wait()
	var converter_waiting: bool=await conversion_waiting("retry-converter")
	var taker:=Thread.new()
	assert(taker.start(race_worker.bind(connection+" application_name=retry-storage-taker"+budgets,[80001,"reselect-take","storage",[uid(9901),1,30]],ready))==OK)
	ready.wait()
	var taker_waiting: bool=await conversion_waiting("retry-storage-taker")
	execute(true,"SELECT pg_advisory_unlock(95126);")
	var converted: Dictionary=converter.wait_to_finish()
	var taken: Dictionary=taker.wait_to_finish()
	clear_conversion_fault("market_commands")
	assert(converter_waiting and taker_waiting and taken.result.ok)
	assert(not converted.result.ok and converted.result.error=="owner" and not converted.committed and conversion_attempts()==1)
	assert(retry_balance()==balance and Ledger.new(pg).receipt(80001,"reselect-deposit").error=="unknown_command")
	var received: Array=rows(true,"SELECT i.amount,i.revision,i.owner_character_id,c.location FROM economy.item_instances i JOIN economy.item_custody c USING(uid) WHERE i.uid='"+uid(9901)+"';")
	assert(received.size()==1 and int(received[0].amount)==20 and int(received[0].revision)==2 and int(received[0].owner_character_id)==80001 and received[0].location=="bag")

func conversion_waiting(label: String) -> bool:
	var deadline: int=Time.get_ticks_msec()+2000
	while Time.get_ticks_msec()<deadline:
		execute(true,"SELECT pg_stat_clear_snapshot();")
		if int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)==1: return true
		await get_tree().create_timer(0.005).timeout
	return false
