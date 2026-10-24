extends Node
## Native Upgrade needs its own atomicity/parity proof; current runtime suites
## remain authoritative for SQLite World/journal/NPC behavior, not PG execution.
const Schema = preload("res://source/server/world/database/postgres/storage_schema_postgres.gd")
const PgItems = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const PgWallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const PgStorage = preload("res://source/server/world/database/postgres/account_storage_postgres.gd")
const PgUpgrade = preload("res://source/server/world/database/postgres/upgrade_store_postgres.gd")
var sqlite: SqliteSoci
var pg: Object
var buyer: int
var alternate: int
var stranger: int
var account: int
var connection: String
var recipe: UpgradeDefinition

func prepared(definition: ItemDefinition, character: int, id: int, amount: int = 1) -> ItemInstance:
	var item:=ItemInstance.create(definition,character,[{"stat":"attack","value":3}])
	item.uid=str(id).pad_zeros(32)
	item.amount=amount
	return item

func seed_item(items: RefCounted, is_pg: bool, definition: ItemDefinition, character: int, id: int, position: int, amount: int = 1) -> void:
	assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
	assert(items.receive_item_in_transaction(prepared(definition,character,id,amount),position).ok)
	assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))

func capture(items: RefCounted, wallets: RefCounted, storage: RefCounted, is_pg: bool) -> Dictionary:
	var inventories: Array=[]
	for character: int in [buyer,alternate,stranger]:
		var inventory: Dictionary=items.inventory(character)
		assert(inventory.ok)
		inventories.append(inventory)
	var count: int
	if is_pg:
		count=int(pg.query("SELECT COUNT(*) AS n FROM economy.market_commands;").rows[0].n)
	else:
		assert(sqlite.query("SELECT COUNT(*) AS n FROM market_commands;"))
		count=int(sqlite.query_result[0].n)
	return {"inventories":inventories,"wallet":wallets.load_wallet(account),"storage":storage.snapshot(buyer),"receipts":count}

func canonical(snapshot: Dictionary) -> Dictionary:
	var result:=snapshot.duplicate(true)
	for inventory: Dictionary in result.inventories: inventory.item_state.erase("authority_id")
	result.wallet.wallet_state.erase("authority_id")
	return result

func fault(is_pg: bool, stage: String) -> void:
	var table: String={"custody":"item_custody","delete":"item_instances","wallet":"account_wallets","target":"item_instances","receipt":"market_commands"}[stage]
	var event: String="DELETE" if stage in ["custody","delete"] else ("INSERT" if stage=="receipt" else "UPDATE")
	var condition: String=" WHEN (NEW.definition_id='iron_sword')" if stage=="target" else ""
	if is_pg:
		assert(pg.execute("CREATE OR REPLACE FUNCTION economy.fixture_upgrade_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'upgrade fixture fault'; END; $$;").ok)
		assert(pg.execute("CREATE TRIGGER fixture_upgrade_fault BEFORE %s ON economy.%s FOR EACH ROW%s EXECUTE FUNCTION economy.fixture_upgrade_fault();" % [event,table,condition]).ok)
	else:
		assert(sqlite.query("CREATE TEMP TRIGGER fixture_upgrade_fault BEFORE %s ON %s%s BEGIN SELECT RAISE(ABORT,'upgrade fixture fault'); END;" % [event,table,condition]))

func clear_fault(is_pg: bool, stage: String) -> void:
	var table: String={"custody":"item_custody","delete":"item_instances","wallet":"account_wallets","target":"item_instances","receipt":"market_commands"}[stage]
	assert(pg.execute("DROP TRIGGER fixture_upgrade_fault ON economy.%s;" % table).ok if is_pg else sqlite.query("DROP TRIGGER fixture_upgrade_fault;"))

func exercise(store: RefCounted, items: RefCounted, wallets: RefCounted, storage: RefCounted, is_pg: bool) -> Array:
	var checkpoints: Array=[]
	for index: int in 5: seed_item(items,is_pg,ItemDefinitions.IRON_SWORD,buyer,index+1,index)
	seed_item(items,is_pg,ItemDefinitions.UPGRADE_ORE,alternate,201,0,10)
	seed_item(items,is_pg,ItemDefinitions.UPGRADE_ORE,buyer,300,12,10)
	assert(storage.transfer_command(buyer,str(300).pad_zeros(32),0,"inventory","storage",0,"put-material").ok)
	assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
	var upgraded_material:=prepared(ItemDefinitions.UPGRADE_ORE,buyer,301,10)
	upgraded_material.upgrade_level=1
	assert(items.receive_item_in_transaction(upgraded_material,12).ok)
	assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))
	assert(storage.transfer_command(buyer,str(5).pad_zeros(32),0,"inventory","storage",1,"put-sword").ok)
	assert(items.inventory_command(buyer,"equip",str(4).pad_zeros(32),0,-1,"equip").ok)
	var uid: String=str(1).pad_zeros(32)
	var original_item: Dictionary={}
	for item: Dictionary in items.inventory(buyer).items:
		if item.uid==uid: original_item=item
	var before:=capture(items,wallets,storage,is_pg)
	assert(store.candidate(buyer,uid,-1,recipe).ok)
	assert(store.upgrade(buyer,600,recipe,uid,0).error=="request")
	assert(store.upgrade(buyer,600,null,uid,0,"null-recipe").error=="request")
	var bad: UpgradeDefinition=recipe.duplicate()
	bad.to_level=2
	assert(store.upgrade(buyer,600,bad,uid,0,"bad-recipe").error=="request")
	assert(store.upgrade(buyer,600,recipe,uid,1,"stale").error=="stale")
	assert(store.upgrade(alternate,600,recipe,uid,0,"other-character").error=="owner")
	assert(store.upgrade(stranger,600,recipe,uid,0,"foreign").error=="owner")
	assert(store.upgrade(buyer,600,recipe,str(4).pad_zeros(32),1,"equipped").error=="placement")
	assert(store.upgrade(buyer,600,recipe,str(5).pad_zeros(32),1,"stored").error=="owner")
	assert(store.upgrade(buyer,600,recipe,uid,0,"missing-material").error=="material", "stored/same-account alt/upgraded materials are ineligible")
	assert(capture(items,wallets,storage,is_pg)==before)
	seed_item(items,is_pg,ItemDefinitions.UPGRADE_ORE,buyer,101,10,2)
	seed_item(items,is_pg,ItemDefinitions.UPGRADE_ORE,buyer,102,11,5)
	var prefix: String="economy." if is_pg else ""
	var reserve_sql: String="UPDATE "+prefix+"account_wallets SET reserved_yang=1500 WHERE account_id="+str(account)+";"
	assert(pg.execute(reserve_sql).ok if is_pg else sqlite.query(reserve_sql))
	before=capture(items,wallets,storage,is_pg)
	assert(store.upgrade(buyer,600,recipe,uid,0,"reserved-funds").error=="funds")
	assert(capture(items,wallets,storage,is_pg)==before, "Upgrade cannot spend reserved funds or partially commit pending income")
	reserve_sql="UPDATE "+prefix+"account_wallets SET reserved_yang=0 WHERE account_id="+str(account)+";"
	assert(pg.execute(reserve_sql).ok if is_pg else sqlite.query(reserve_sql))
	before=capture(items,wallets,storage,is_pg)
	assert(store.upgrade(buyer,0,recipe,uid,0,"funds").error=="funds")
	assert(store.upgrade(buyer,-1,recipe,uid,0,"bad-pending").error=="request")
	assert(store.upgrade(buyer,600,recipe,str(102).pad_zeros(32),0,"not-a-sword").error=="unsupported_item")
	assert(capture(items,wallets,storage,is_pg)==before)
	for stage: String in ["custody","delete","wallet","target","receipt"]:
		fault(is_pg,stage)
		assert(store.upgrade(buyer,600,recipe,uid,0,"fault-"+stage).error=="storage")
		assert(not store.committed and capture(items,wallets,storage,is_pg)==before, "material, custody, pending Yang, spend, target and receipt roll back together")
		clear_fault(is_pg,stage)
	var upgraded: Dictionary=store.upgrade(buyer,600,recipe,uid,0,"paid")
	assert(upgraded.ok and store.committed and upgraded.balance==100 and upgraded.wallet_states[0].pending_applied==600)
	var found: Dictionary={}
	for item: Dictionary in items.inventory(buyer).items:
		assert(item.uid!=str(101).pad_zeros(32))
		if item.uid==uid: found=item
		if item.uid==str(102).pad_zeros(32): assert(item.amount==4 and item.revision==1)
	assert(found.upgrade_level==1 and found.revision==1 and found.bag_position==0)
	assert(found.affixes==original_item.affixes and found.sockets==original_item.sockets, "Upgrade must preserve persisted rolls and sockets")
	checkpoints.append(canonical(capture(items,wallets,storage,is_pg)))
	var attack_before: float=items.inventory(buyer).stats.attack
	assert(items.inventory_command(buyer,"equip",uid,1,-1,"equip-upgraded").ok)
	assert(items.inventory(buyer).stats.attack>attack_before, "read snapshot reflects equipped upgraded stats")
	before=capture(items,wallets,storage,is_pg)
	assert(store.upgrade_receipt(buyer,"paid")==upgraded)
	assert(store.upgrade_receipt(alternate,"paid").error=="unknown_command")
	assert(store.upgrade_receipt(stranger,"paid").error=="unknown_command")
	assert(store.upgrade_receipt(buyer,"equip").error=="unknown_command")
	assert(store.upgrade_receipt(buyer,"absent").error=="unknown_command")
	assert(store.upgrade(alternate,600,recipe,uid,0,"paid").error=="command_conflict")
	assert(store.upgrade(buyer,600,recipe,uid,1,"paid").error=="command_conflict")
	assert(store.upgrade(buyer,9999,recipe,uid,0,"paid")==upgraded and not store.committed)
	assert(capture(items,wallets,storage,is_pg)==before, "replay cannot reapply newer pending income or historical placement")
	assert(wallets.checkpoint({account:4000}).ok)
	var second: String=str(2).pad_zeros(32)
	assert(store.upgrade(buyer,0,recipe,second,0,"second").ok)
	var whole: UpgradeDefinition=recipe.duplicate()
	whole.upgrade_id=&"whole_stack_fixture"
	whole.material_amount=1
	var third: String=str(3).pad_zeros(32)
	before=capture(items,wallets,storage,is_pg)
	fault(is_pg,"target")
	assert(store.upgrade(buyer,0,whole,third,0,"whole").error=="storage")
	assert(capture(items,wallets,storage,is_pg)==before, "whole stack and custody deletion restore on late target failure")
	clear_fault(is_pg,"target")
	assert(store.upgrade(buyer,0,whole,third,0,"whole").ok)
	assert(not items.inventory(buyer).items.any(func(i: Dictionary) -> bool: return i.uid==str(102).pad_zeros(32)))
	before=capture(items,wallets,storage,is_pg)
	assert(store.upgrade(buyer,0,recipe,third,1,"already-plus-one").error=="upgrade_level")
	# Reconstruct connection/store after all eligible materials were consumed.
	if is_pg:
		pg.close()
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
		store=PgUpgrade.new(pg)
	else:
		assert(sqlite.close_db() and sqlite.open_db())
		store=UpgradeStoreSqlite.new(sqlite)
	assert(store.upgrade(buyer,7777,recipe,uid,0,"paid")==upgraded and not store.committed)
	assert(store.upgrade_receipt(buyer,"paid")==upgraded)
	for index: int in 30:
		assert(store.upgrade(buyer,600,recipe,str(5).pad_zeros(32),1,"reject-"+str(index)).error=="owner")
	assert(capture(items,wallets,storage,is_pg)==before)
	checkpoints.append(canonical(before))
	return checkpoints

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	recipe=UpgradeDefinition.new()
	recipe.upgrade_id=&"pg_upgrade_fixture"
	recipe.item_definition_id=&"iron_sword"
	recipe.material_definition_id=&"upgrade_ore"
	recipe.material_amount=3
	recipe.yang_cost=2000
	assert(recipe.validation_errors().is_empty())
	sqlite=SqliteSoci.new()
	sqlite.path=directory+"/upgrade.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	buyer=EconomyFixture.create_character(identities,"pg-upgrade-a",{"name":"A","skin":1})
	alternate=EconomyFixture.create_character(identities,"pg-upgrade-a",{"name":"Alt","skin":1})
	stranger=EconomyFixture.create_character(identities,"pg-upgrade-b",{"name":"B","skin":1})
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	account=identities.resolve_account_id(buyer)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	var items:=PgItems.new(pg)
	for character: int in [buyer,alternate,stranger]:
		var id:=identities.resolve_account_id(character)
		assert(PgWallet.new(pg).initialize_account(id).ok and items.bind_character(character,id))
	var baseline:=exercise(UpgradeStoreSqlite.new(sqlite),ItemStoreSqlite.new(sqlite),WalletStoreSqlite.new(sqlite),AccountStorageSqlite.new(sqlite),false)
	var candidate:=exercise(PgUpgrade.new(pg),items,PgWallet.new(pg),PgStorage.new(pg),true)
	assert(baseline==candidate, "Upgrade/material/custody/wallet/revision/receipt snapshots match SQLite")
	native_checks(items)
	await retry_checks(items)
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(sqlite.path+suffix))
	print("POSTGRES_UPGRADE_OK SQLite parity: ordered material stacks, pending Yang/spend, same UID upgrade, stats, receipts/reopen and atomic failures")
	get_tree().quit()

func native_checks(items: RefCounted) -> void:
	var character: int=90001
	var owner_account: int=9000
	assert(PgWallet.new(pg).initialize_account(owner_account).ok and items.bind_character(character,owner_account))
	seed_item(items,true,ItemDefinitions.IRON_SWORD,character,901,0)
	seed_item(items,true,ItemDefinitions.UPGRADE_ORE,character,903,10,4)
	var store:=PgUpgrade.new(pg)
	var simple: UpgradeDefinition=recipe.duplicate()
	simple.material_amount=1
	simple.yang_cost=1000
	var before: Dictionary={"items":items.inventory(character),"wallet":PgWallet.new(pg).load_wallet(owner_account)}
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_upgrade_fault();").ok)
	var uncertain: Dictionary=store.upgrade(character,123,simple,str(901).pad_zeros(32),0,"deferred")
	assert(uncertain.get("outcome_unknown",false) and not pg.is_open() and not store.committed)
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	assert(pg.execute("DROP TRIGGER fixture_commit ON economy.market_commands;").ok)
	assert({"items":items.inventory(character),"wallet":PgWallet.new(pg).load_wallet(owner_account)}==before)
	assert(store.upgrade_receipt(character,"deferred").error=="unknown_command")
	var result: Dictionary=store.upgrade(character,123,simple,str(901).pad_zeros(32),0,"deferred")
	assert(result.ok and result.balance==623)
	assert(pg.begin())
	assert(store.upgrade(character,0,simple,str(901).pad_zeros(32),1,"nested").error=="storage")
	assert(pg.in_transaction() and pg.rollback())
	var large: int=9007199254741133
	assert(items.bind_character(large,owner_account))
	seed_item(items,true,ItemDefinitions.IRON_SWORD,large,904,0)
	seed_item(items,true,ItemDefinitions.UPGRADE_ORE,large,905,10,1)
	assert(pg.execute("UPDATE economy.item_instances SET revision=9007199254741033 WHERE uid=:uid;",{"uid":str(904).pad_zeros(32)}).ok)
	assert(pg.execute("UPDATE economy.account_item_revisions SET revision=9007199254741033 WHERE account_id=9000;").ok)
	# Controlled INSERT seed: the normal UPDATE trigger deliberately owns revision.
	assert(pg.execute("DELETE FROM economy.account_wallets WHERE account_id=9000;").ok)
	assert(pg.execute("INSERT INTO economy.account_wallets(account_id,yang,wallet_revision) VALUES(9000,623,9007199254741033);").ok)
	result=store.upgrade(large,600,simple,str(904).pad_zeros(32),9007199254741033,"large-issuer")
	assert(result.ok and result.item_state.character_id==large and result.item_state.revision>9007199254741033)
	assert(result.wallet_states[0].revision>9007199254741033 and store.upgrade_receipt(large,"large-issuer")==result)
	assert(items.inventory(large).items[0].revision==9007199254741034)
	assert(store.upgrade(large,9999,simple,str(904).pad_zeros(32),9007199254741033,"large-issuer")==result)
	assert(store.upgrade_receipt(character,"large-issuer").error=="unknown_command")

func retry_checks(items: RefCounted) -> void:
	assert(PgWallet.new(pg).initialize_account(8100).ok)
	assert(pg.execute("UPDATE economy.account_wallets SET yang=100000 WHERE account_id=8100;").ok)
	assert(pg.execute("CREATE SEQUENCE economy.fixture_upgrade_attempt;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_upgrade_retry() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE attempt BIGINT; BEGIN attempt:=nextval('economy.fixture_upgrade_attempt'); IF attempt<=TG_ARGV[1]::BIGINT THEN IF TG_NARGS>2 THEN PERFORM pg_advisory_xact_lock(95127); END IF; RAISE EXCEPTION 'upgrade retry fixture' USING ERRCODE=TG_ARGV[0]; END IF; IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW; END; $$;").ok)
	var store:=PgUpgrade.new(pg)
	var accepted: UpgradeDefinition=recipe.duplicate(true)
	accepted.yang_cost=100
	var index: int=0
	for stage: String in ["custody","delete","partial","wallet","target","receipt"]:
		for code: String in ["40001","40P01"]:
			var character: int=81000+index
			var id: int=10000+index*3
			retry_seed(items,character,id)
			var original: Dictionary=items.inventory(character).items.filter(func(item: Dictionary) -> bool: return item.uid==str(id).pad_zeros(32))[0]
			var balance: int=PgWallet.new(pg).load_wallet(8100).balance
			upgrade_retry_fault(stage,code,1)
			var command: String="retry-upgrade-"+str(index)
			var result: Dictionary=store.upgrade(character,17,accepted,str(id).pad_zeros(32),0,command)
			assert(result.ok and store.committed and upgrade_attempts()==2 and result.balance==balance+17-100)
			assert(result.wallet_states[0].pending_applied==17 and PgWallet.new(pg).load_wallet(8100).balance==result.balance)
			var inventory: Array=items.inventory(character).items
			assert(inventory.size()==2,"first material stack is consumed once, second is reduced once")
			for item: Dictionary in inventory:
				if item.uid==str(id).pad_zeros(32): assert(item.upgrade_level==1 and item.revision==1 and item.bag_position==0 and item.affixes==original.affixes and item.sockets==original.sockets)
				else: assert(item.uid==str(id+2).pad_zeros(32) and item.amount==4 and item.revision==1)
			var before:=retry_state()
			assert(store.upgrade(character,9999,accepted,str(id).pad_zeros(32),0,command)==result and not store.committed and retry_state()==before and upgrade_attempts()==2)
			assert(store.upgrade_receipt(character,command)==result)
			clear_upgrade_retry(stage)
			index+=1
	var character: int=81900
	var id: int=10900
	retry_seed(items,character,id)
	for code: String in ["40001","40P01","23505","55P03","57014"]:
		upgrade_retry_fault("receipt",code,99)
		var before:=retry_state()
		var result: Dictionary=store.upgrade(character,17,accepted,str(id).pad_zeros(32),0,"exhausted-"+code)
		assert(result.error=="storage" and not store.committed and not pg.in_transaction() and retry_state()==before)
		assert(upgrade_attempts()==(3 if code in ["40001","40P01"] else 1))
		clear_upgrade_retry("receipt")
	for code: String in ["40001","40P01"]:
		upgrade_retry_fault("receipt",code,99,true)
		var before:=retry_state()
		var result: Dictionary=store.upgrade(character,17,accepted,str(id).pad_zeros(32),0,"unknown-"+code)
		assert(result.get("outcome_unknown",false) and not store.committed and not pg.is_open())
		assert(pg.open("postgresql",connection) and upgrade_attempts()==1)
		clear_upgrade_retry("receipt")
		assert(retry_state()==before and store.upgrade_receipt(character,"unknown-"+code).error=="unknown_command")
	for target: bool in [false,true]: await retry_reselection(items,accepted,target)
	print("POSTGRES_UPGRADE_RETRY_OK material deletion/remainder, pending/spend/target/receipt atomicity, exact replay, bounded attempts, no COMMIT retry and current target/material reselection")

func retry_seed(items: RefCounted, character: int, id: int) -> void:
	assert(items.bind_character(character,8100))
	seed_item(items,true,ItemDefinitions.IRON_SWORD,character,id,0)
	seed_item(items,true,ItemDefinitions.UPGRADE_ORE,character,id+1,10,2)
	seed_item(items,true,ItemDefinitions.UPGRADE_ORE,character,id+2,11,5)

func retry_state() -> Array:
	var snapshot: Array=[]
	for table: String in ["item_instances","item_custody","account_item_revisions","account_wallets","market_commands"]:
		var result: Dictionary=pg.query("SELECT row_to_json(t)::text AS value FROM economy."+table+" t ORDER BY row_to_json(t)::text;",{},10000)
		assert(result.ok and not result.truncated)
		snapshot.append(result.rows)
	return snapshot

func upgrade_retry_fault(stage: String, code: String, failures: int, deferred: bool = false) -> void:
	assert(pg.execute("ALTER SEQUENCE economy.fixture_upgrade_attempt RESTART WITH 1;").ok)
	var table: String=upgrade_retry_table(stage)
	var event: String="DELETE" if stage in ["custody","delete"] else ("INSERT" if stage=="receipt" else "UPDATE")
	var condition: String=""
	if stage in ["target","partial"]: condition=" WHEN (NEW.definition_id='%s')" % ("iron_sword" if stage=="target" else "upgrade_ore")
	if stage=="wallet": condition=" WHEN (NEW.yang<OLD.yang)"
	var create: String="CREATE CONSTRAINT TRIGGER fixture_retry AFTER INSERT ON economy.%s DEFERRABLE INITIALLY DEFERRED" % table if deferred else "CREATE TRIGGER fixture_retry BEFORE %s ON economy.%s" % [event,table]
	assert(pg.execute(create+" FOR EACH ROW"+condition+" EXECUTE FUNCTION economy.fixture_upgrade_retry('%s','%d');" % [code,failures]).ok)

func upgrade_retry_table(stage: String) -> String:
	return {"custody":"item_custody","delete":"item_instances","partial":"item_instances","wallet":"account_wallets","target":"item_instances","receipt":"market_commands"}[stage]

func clear_upgrade_retry(stage: String) -> void:
	assert(pg.execute("DROP TRIGGER fixture_retry ON economy."+upgrade_retry_table(stage)+";").ok)

func upgrade_attempts() -> int:
	return int(pg.query("SELECT last_value FROM economy.fixture_upgrade_attempt;").rows[0].last_value)

func retry_reselection(items: RefCounted, accepted: UpgradeDefinition, target: bool) -> void:
	var character: int=81911 if target else 81910
	var id: int=11010 if target else 11000
	retry_seed(items,character,id)
	var balance: int=PgWallet.new(pg).load_wallet(8100).balance
	assert(pg.execute("ALTER SEQUENCE economy.fixture_upgrade_attempt RESTART WITH 1;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_retry BEFORE INSERT ON economy.market_commands FOR EACH ROW WHEN (current_setting('application_name')='retry-upgrader') EXECUTE FUNCTION economy.fixture_upgrade_retry('40001','1','gate');").ok)
	assert(pg.execute("SELECT pg_advisory_lock(95127);").ok)
	# Coordination probe only, not a change to normal fixture timeout budgets.
	var budgets: String=" options='-c statement_timeout=10000 -c lock_timeout=8000 -c idle_in_transaction_session_timeout=10000'"
	var ready:=Semaphore.new()
	var original: UpgradeDefinition=accepted.duplicate(true)
	var upgrader:=Thread.new()
	assert(upgrader.start(upgrade_worker.bind(connection+" application_name=retry-upgrader"+budgets,character,id,original,ready))==OK)
	ready.wait()
	var upgrading: bool=await upgrade_waiting("retry-upgrader")
	var editor:=Thread.new()
	assert(editor.start(edit_worker.bind(connection+" application_name=retry-upgrade-editor"+budgets,character,id,target,ready))==OK)
	ready.wait()
	var editing: bool=await upgrade_waiting("retry-upgrade-editor")
	# The accepted operation keeps its captured recipe while live server content
	# changes; new calls may use the new values, retries keep the accepted costs.
	original.yang_cost=9999
	original.material_amount=999
	assert(pg.execute("SELECT pg_advisory_unlock(95127);").ok)
	var upgraded: Dictionary=upgrader.wait_to_finish()
	var edited: Dictionary=editor.wait_to_finish()
	clear_upgrade_retry("receipt")
	assert(upgrading and editing and edited.ok)
	var inventory: Array=items.inventory(character).items
	if target:
		assert(upgraded.result.error=="stale" and not upgraded.committed and upgrade_attempts()==1)
		assert(PgWallet.new(pg).load_wallet(8100).balance==balance)
		assert(PgUpgrade.new(pg).upgrade_receipt(character,"reselection-"+str(character)).error=="unknown_command")
		assert(inventory.any(func(item: Dictionary) -> bool: return item.uid==str(id).pad_zeros(32) and item.upgrade_level==0 and item.revision==1 and item.bag_position==20))
		assert(inventory.any(func(item: Dictionary) -> bool: return item.uid==str(id+1).pad_zeros(32) and item.amount==2 and item.revision==0))
		assert(inventory.any(func(item: Dictionary) -> bool: return item.uid==str(id+2).pad_zeros(32) and item.amount==5 and item.revision==0))
	else:
		assert(upgraded.result.ok and upgraded.committed and upgrade_attempts()==2)
		assert(PgWallet.new(pg).load_wallet(8100).balance==balance+17-100)
		assert(inventory.any(func(item: Dictionary) -> bool: return item.uid==str(id).pad_zeros(32) and item.upgrade_level==1 and item.revision==1))
		assert(inventory.any(func(item: Dictionary) -> bool: return item.uid==str(id+2).pad_zeros(32) and item.amount==2 and item.revision==1),"retry reselects current materials instead of reusing the deleted first-attempt stack")
		assert(PgStorage.new(pg).snapshot(character).items.any(func(item: Dictionary) -> bool: return item.uid==str(id+1).pad_zeros(32) and item.amount==2))

func upgrade_waiting(label: String) -> bool:
	var deadline: int=Time.get_ticks_msec()+2000
	while Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		if int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)==1: return true
		await get_tree().create_timer(0.005).timeout
	return false

func upgrade_worker(dsn: String, character: int, id: int, accepted: UpgradeDefinition, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"result":{"ok":false,"error":"fixture_connection"},"committed":false}
	var store:=PgUpgrade.new(database)
	var result: Dictionary=store.upgrade(character,17,accepted,str(id).pad_zeros(32),0,"reselection-"+str(character))
	var committed: bool=store.committed
	database.close()
	return {"result":result,"committed":committed}

func edit_worker(dsn: String, character: int, id: int, target: bool, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"ok":false,"error":"fixture_connection"}
	var result: Dictionary=PgItems.new(database).inventory_command(character,"move",str(id).pad_zeros(32),0,20,"reselect-target") if target else PgStorage.new(database).transfer_command(character,str(id+1).pad_zeros(32),0,"inventory","storage",20,"reselect-material")
	database.close()
	return result
