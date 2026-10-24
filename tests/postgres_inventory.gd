extends Node
## Opt-in native PostgreSQL / migrated SQLite behavior parity. Owned fixtures only.
const Schema = preload("res://source/server/world/database/postgres/inventory_schema_postgres.gd")
const PgItems = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const PgWallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var sqlite: SqliteSoci
var pg: Object
var buyer: int
var alternate: int
var stranger: int
var connection: String

func sql(is_pg: bool, statement: String) -> bool:
	return pg.execute(statement).ok if is_pg else sqlite.query(statement)

func capture(items: RefCounted, is_pg: bool, character: int = -1) -> Dictionary:
	var table: String="economy." if is_pg else ""
	var counts: Array=[]
	for name: String in ["market_commands","ground_item_claims","item_initializations"]:
		var query: String="SELECT COUNT(*) AS n FROM "+table+name+";"
		if is_pg:
			var result: Dictionary=pg.query(query)
			assert(result.ok)
			counts.append(int(result.rows[0].n))
		else:
			assert(sqlite.query(query))
			counts.append(int(sqlite.query_result[0].n))
	var inventory: Dictionary=items.inventory(buyer if character==-1 else character)
	assert(inventory.ok)
	return {"inventory":inventory,"counts":counts}

func canonical(snapshot: Dictionary, aliases: Dictionary) -> Dictionary:
	var result:=snapshot.duplicate(true)
	result.inventory.item_state.erase("authority_id")
	for item: Dictionary in result.inventory.items: item.uid=aliases.get(item.uid,item.uid)
	for slot: String in result.inventory.equipment:
		result.inventory.equipment[slot]=aliases.get(result.inventory.equipment[slot],result.inventory.equipment[slot])
	result.inventory.items.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return a.uid<b.uid)
	return result

func fault(is_pg: bool, table: String, event: String) -> void:
	if is_pg:
		assert(sql(is_pg,"CREATE OR REPLACE FUNCTION economy.fixture_inventory_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'inventory fixture fault'; END; $$;"))
		assert(sql(is_pg,"CREATE TRIGGER fixture_inventory_fault BEFORE %s ON economy.%s FOR EACH ROW EXECUTE FUNCTION economy.fixture_inventory_fault();" % [event,table]))
	else:
		assert(sql(is_pg,"CREATE TEMP TRIGGER fixture_inventory_fault BEFORE %s ON %s BEGIN SELECT RAISE(ABORT,'inventory fixture fault'); END;" % [event,table]))

func clear_fault(is_pg: bool, table: String) -> void:
	assert(sql(is_pg,"DROP TRIGGER fixture_inventory_fault ON economy.%s;" % table if is_pg else "DROP TRIGGER fixture_inventory_fault;"))

func command(items: RefCounted, action: String, uid: String, revision: int, position: int, id: String) -> Dictionary:
	return items.inventory_command(buyer,action,uid,revision,position,id)

func prepared(definition: ItemDefinition, character: int, identity: int) -> ItemInstance:
	var item:=ItemInstance.create(definition,character,[])
	item.uid=str(identity).pad_zeros(32)
	return item

func exercise(items: RefCounted, is_pg: bool) -> Array:
	var checkpoints: Array=[]
	var before:=capture(items,is_pg)
	assert(items.initialize_character(999999).error=="owner")
	fault(is_pg,"item_initializations","INSERT")
	assert(items.initialize_character(buyer).error=="storage")
	assert(capture(items,is_pg)==before, "starter items and account revision roll back with marker")
	clear_fault(is_pg,"item_initializations")
	assert(items.initialize_character(buyer).ok and items.committed)
	before=capture(items,is_pg)
	assert(items.initialize_character(buyer).ok and not items.committed)
	assert(capture(items,is_pg)==before)
	var first: String=before.inventory.items[0].uid
	var second: String=before.inventory.items[1].uid
	var aliases: Dictionary={first:"starter-0",second:"starter-1"}
	checkpoints.append(canonical(before,aliases))
	var moved:=command(items,"move",first,0,10,"move")
	assert(moved.ok and items.committed and not items.receipt_replay)
	assert(command(items,"move",second,0,10,"overlap").error=="occupied")
	assert(command(items,"move",first,0,20,"stale").error=="stale")
	assert(command(items,"move",first,1,40,"page-edge").error=="request")
	assert(items.inventory_command(stranger,"equip",first,1,-1,"owner").error=="owner")
	assert(command(items,"equip",first,1,-1,"equip").ok)
	assert(items.inventory(buyer).stats.attack==23)
	assert(command(items,"move",first,2,10,"equipped-move").error=="placement")
	# Activation of an equipped item is a successful no-op, not a toggle.
	var no_op:=command(items,"activate",first,2,-1,"no-op")
	assert(no_op.ok and not items.committed and not items.receipt_replay)
	assert(command(items,"activate",first,2,-1,"no-op")==no_op and items.receipt_replay and not items.committed)
	assert(command(items,"activate",second,0,-1,"swap").ok)
	assert(items.inventory(buyer).stats.attack==27)
	checkpoints.append(canonical(capture(items,is_pg),aliases))
	assert(command(items,"unequip",second,1,10,"unequip").ok)
	assert(items.inventory(buyer).stats.attack==10)
	assert(command(items,"unequip",second,2,10,"bag-target").error=="placement")
	assert(command(items,"unequip",second,2,-1,"bag-no-op").ok and not items.committed)
	assert(command(items,"move",second,2,10,"same-cell").ok and not items.committed)
	assert(items.inventory_receipt(alternate,"move").error=="unknown_command")
	assert(items.inventory_receipt(stranger,"move").error=="unknown_command")
	assert(items.inventory_command(alternate,"move",first,0,10,"move").error=="command_conflict")
	assert(command(items,"move",first,0,11,"move").error=="command_conflict")
	before=capture(items,is_pg)
	# Reopen/lost response: original revision and placement are obsolete, but the
	# same command must recover its ORIGINAL result without touching either item.
	if is_pg:
		pg.close()
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
		items=PgItems.new(pg)
	else:
		assert(sqlite.close_db() and sqlite.open_db())
		items=ItemStoreSqlite.new(sqlite)
	assert(command(items,"move",first,0,10,"move")==moved)
	assert(items.inventory_receipt(buyer,"move")==moved)
	assert(not items.committed and items.receipt_replay)
	assert(items.initialize_character(buyer).ok and capture(items,is_pg)==before)
	for stage: String in ["item_instances","market_commands"]:
		fault(is_pg,stage,"UPDATE" if stage=="item_instances" else "INSERT")
		assert(command(items,"move",second,2,20,"fault-"+stage).error=="storage")
		assert(capture(items,is_pg)==before, "placement, revision and receipt roll back together")
		clear_fault(is_pg,stage)
	# SQLite's legacy item_placements is now a view over canonical custody.
	var custody: String="item_custody"
	fault(is_pg,custody,"INSERT")
	assert(command(items,"equip",second,2,-1,"fault-equip").error=="storage")
	assert(capture(items,is_pg)==before, "deleted custody restored after failed equip")
	var drop:=prepared(ItemDefinitions.UPGRADE_ORE,buyer,900)
	assert(items.claim_ground_item(buyer,drop.uid,drop).error=="storage")
	assert(capture(items,is_pg)==before, "ground marker, item and revision roll back together")
	clear_fault(is_pg,custody)
	assert(items.claim_ground_item(buyer,drop.uid,drop).ok)
	before=capture(items,is_pg)
	assert(items.claim_ground_item(buyer,drop.uid,drop).error=="claimed")
	assert(items.claim_ground_item(stranger,drop.uid,drop).error=="claimed")
	assert(command(items,"activate",drop.uid,0,-1,"no-action").error=="no_action")
	assert(capture(items,is_pg)==before)
	# Shared layout logic covers all supported heights, not only current swords.
	var ore: ItemDefinition=ItemDefinitions.get_definition(&"upgrade_ore")
	var original_height: int=ore.inventory_height
	ore.inventory_height=3
	assert(command(items,"move",drop.uid,0,30,"three-high").ok)
	assert(command(items,"move",drop.uid,1,35,"three-edge").error=="request")
	assert(command(items,"move",second,2,35,"three-overlap").error=="occupied")
	assert(command(items,"move",drop.uid,1,2,"restore-height").ok)
	ore.inventory_height=original_height
	assert(command(items,"equip",second,2,-1,"before-full").ok)
	# Fail after BOTH sides of a swap have been relocated: item revision UPDATE.
	before=capture(items,is_pg)
	fault(is_pg,"item_instances","UPDATE")
	assert(command(items,"equip",first,3,-1,"fault-swap").error=="storage")
	assert(capture(items,is_pg)==before)
	clear_fault(is_pg,"item_instances")
	# Fill bag with prepared one-cell items; no economy randomness in comparison.
	assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
	var occupied: Dictionary={}
	for item: Dictionary in before.inventory.items:
		if item.location=="bag":
			for cell: int in InventoryGrid.cells(item.bag_position,item.inventory_height): occupied[cell]=true
	for cell: int in InventoryGrid.CAPACITY:
		if occupied.has(cell): continue
		var filler:=prepared(ItemDefinitions.UPGRADE_ORE,buyer,1000+cell)
		assert(items.receive_item_in_transaction(filler,cell).ok)
	assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))
	before=capture(items,is_pg)
	assert(command(items,"unequip",second,3,-1,"full-unequip").error=="bag_full")
	var full_drop:=prepared(ItemDefinitions.UPGRADE_ORE,buyer,901)
	assert(items.claim_ground_item(buyer,full_drop.uid,full_drop).error=="bag_full")
	assert(command(items,"move",first,0,10,"move")==moved)
	assert(capture(items,is_pg)==before)
	for index: int in 40:
		assert(command(items,"move",second,3,10,"reject-"+str(index)).error=="placement")
	assert(capture(items,is_pg)==before, "rejects do not grow receipt/claim tables")
	checkpoints.append(canonical(before,aliases))
	# A full-bag rejection must not consume the drop UID: free one cell and retry
	# the SAME prepared drop, then reopen to check the durable claim marker.
	assert(pg.begin() if is_pg else sqlite.query("BEGIN IMMEDIATE;"))
	var prefix: String="economy." if is_pg else ""
	assert(sql(is_pg,"DELETE FROM "+prefix+"item_custody WHERE uid='"+str(1000).pad_zeros(32)+"';"))
	assert(sql(is_pg,"DELETE FROM "+prefix+"item_instances WHERE uid='"+str(1000).pad_zeros(32)+"';"))
	assert(pg.commit() if is_pg else sqlite.query("COMMIT;"))
	assert(items.claim_ground_item(buyer,full_drop.uid,full_drop).ok)
	before=capture(items,is_pg)
	if is_pg:
		pg.close()
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	else:
		assert(sqlite.close_db() and sqlite.open_db())
	assert(items.claim_ground_item(buyer,full_drop.uid,full_drop).error=="claimed")
	assert(capture(items,is_pg)==before)
	checkpoints.append(canonical(before,aliases))
	return checkpoints

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var directory:=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	sqlite=SqliteSoci.new()
	sqlite.path=directory+"/inventory.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var identities:=WorldStoreSqlite.new(sqlite)
	buyer=EconomyFixture.create_character(identities,"pg-inventory-a",{"name":"A","skin":1})
	alternate=EconomyFixture.create_character(identities,"pg-inventory-a",{"name":"Alt","skin":1})
	stranger=EconomyFixture.create_character(identities,"pg-inventory-b",{"name":"B","skin":1})
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=identities
	EconomyFixture.prepare(runtime)
	connection=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	var items:=PgItems.new(pg)
	for character: int in [buyer,alternate,stranger]:
		var account:=identities.resolve_account_id(character)
		assert(PgWallet.new(pg).initialize_account(account).ok and items.bind_character(character,account))
	assert(Schema.ensure_schema(pg))
	var baseline:=exercise(ItemStoreSqlite.new(sqlite),false)
	var candidate:=exercise(items,true)
	assert(baseline==candidate, "Inventory snapshots, stats, revisions and marker counts match SQLite")
	# Native deferred COMMIT failure is UNKNOWN, never an automatic new intent.
	assert(items.initialize_character(alternate).ok)
	var alt_before:=capture(items,true,alternate)
	var uid: String=alt_before.inventory.items[0].uid
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_inventory_fault();").ok)
	var uncertain: Dictionary=items.inventory_command(alternate,"equip",uid,0,-1,"commit-fault")
	assert(not uncertain.ok and uncertain.get("outcome_unknown",false) and not pg.is_open() and not items.committed)
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	assert(pg.execute("DROP TRIGGER fixture_commit ON economy.market_commands;").ok)
	assert(capture(items,true,alternate)==alt_before)
	assert(items.inventory_receipt(alternate,"commit-fault").error=="unknown_command")
	assert(items.inventory_command(alternate,"equip",uid,0,-1,"commit-fault").ok)
	assert(pg.begin())
	assert(items.inventory_command(alternate,"equip",uid,1,-1,"nested").error=="storage")
	assert(items.initialize_character(alternate).error=="storage")
	var nested_drop:=prepared(ItemDefinitions.UPGRADE_ORE,alternate,902)
	assert(items.claim_ground_item(alternate,nested_drop.uid,nested_drop).error=="storage")
	assert(pg.in_transaction() and pg.rollback(), "standalone APIs must not terminate a caller transaction")
	# Pickup/initialization also retire the native session on ambiguous COMMIT.
	for table: String in ["ground_item_claims","item_initializations"]:
		var character: int=alternate if table=="ground_item_claims" else stranger
		var before:=capture(items,true,character)
		assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_commit AFTER INSERT ON economy.%s DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_inventory_fault();" % table).ok)
		uncertain=items.claim_ground_item(alternate,nested_drop.uid,nested_drop) if table=="ground_item_claims" else items.initialize_character(stranger)
		assert(uncertain.get("outcome_unknown",false) and not pg.is_open() and not items.committed)
		assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
		assert(pg.execute("DROP TRIGGER fixture_commit ON economy.%s;" % table).ok)
		assert(capture(items,true,character)==before)
	assert(items.claim_ground_item(alternate,nested_drop.uid,nested_drop).ok)
	assert(items.initialize_character(stranger).ok)
	# Recovery is character- and kind-scoped even within one account.
	var account: int=items.read_state(alternate).account_id
	assert(pg.execute("INSERT INTO economy.market_commands(account_id,command_id,character_id,kind,request_json,result_json) VALUES(:account,'other-kind',:character,'npc_shop.buy','[]','{\"ok\":true}');",{"account":account,"character":alternate}).ok)
	assert(items.inventory_receipt(alternate,"other-kind").error=="unknown_command")
	assert(items.inventory_command(alternate,"equip",uid,1,-1,"other-kind").error=="command_conflict")
	assert(pg.execute("UPDATE economy.schema_versions SET version=999 WHERE feature='inventory';").ok)
	assert(not Schema.ensure_schema(pg) and not pg.in_transaction())
	assert(pg.execute("UPDATE economy.schema_versions SET version=1 WHERE feature='inventory';").ok and Schema.ensure_schema(pg))
	await retry_checks(items)
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(sqlite.path+suffix))
	print("POSTGRES_INVENTORY_OK SQLite parity: starter/pickup, move/equip/swap/activate/unequip, stats, receipts, reopen, full bag and atomic failures")
	get_tree().quit()

func retry_checks(items: RefCounted) -> void:
	assert(PgWallet.new(pg).initialize_account(8300).ok)
	assert(pg.execute("CREATE SEQUENCE economy.fixture_item_attempt;").ok)
	assert(pg.execute("CREATE FUNCTION economy.fixture_item_retry() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE attempt BIGINT; BEGIN attempt:=nextval('economy.fixture_item_attempt'); IF attempt<=TG_ARGV[1]::BIGINT THEN IF TG_NARGS>2 THEN PERFORM pg_advisory_xact_lock(95129); END IF; RAISE EXCEPTION 'item retry fixture' USING ERRCODE=TG_ARGV[0]; END IF; RETURN NEW; END; $$;").ok)
	var index: int=0
	for action: String in ["move","equip","activate","unequip","swap"]:
		for stage: String in ["placement","revision","receipt"]:
			for code: String in ["40001","40P01"]:
				var character: int=83000+index
				var id: int=20000+index*3
				retry_seed(items,character,id,action in ["unequip","swap"])
				var before: Dictionary=items.inventory(character)
				var target: int=id+1 if action=="swap" else id
				var revision: int=1 if action=="unequip" else 0
				var destination: int=25 if action in ["move","unequip"] else -1
				var kind: String="equip" if action=="swap" else action
				item_retry_fault(stage,kind,retry_uid(target),code,1)
				var command_id: String="retry-item-"+str(index)
				var result: Dictionary=items.inventory_command(character,kind,retry_uid(target),revision,destination,command_id)
				assert(result.ok and items.committed and not items.receipt_replay and item_attempts()==2,str(result))
				var after: Dictionary=items.inventory(character)
				assert(after.items.size()==before.items.size() and after.item_state==result.item_state)
				var selected: Dictionary=after.items.filter(func(item: Dictionary) -> bool: return item.uid==retry_uid(target))[0]
				assert(selected.revision==revision+1)
				if action in ["move","unequip"]: assert(selected.location=="bag" and selected.bag_position==destination)
				else: assert(selected.location=="equipment" and after.equipment.weapon==selected.uid)
				if action=="swap":
					var previous: Dictionary=after.items.filter(func(item: Dictionary) -> bool: return item.uid==retry_uid(id))[0]
					assert(previous.location=="bag" and previous.bag_position==10 and previous.revision==2)
				if action=="move": assert(after.stats==before.stats)
				elif action=="unequip": assert(after.stats.attack<before.stats.attack)
				else: assert(after.stats.attack>before.stats.attack)
				var state:=retry_state()
				assert(items.inventory_command(character,kind,retry_uid(target),revision,destination,command_id)==result and not items.committed and items.receipt_replay and retry_state()==state and item_attempts()==2)
				assert(items.inventory_receipt(character,command_id)==result)
				clear_item_retry(stage)
				index+=1
	var character: int=83900
	var id: int=20900
	retry_seed(items,character,id,false)
	for code: String in ["40001","40P01","23505","55P03","57014"]:
		item_retry_fault("receipt","move",retry_uid(id),code,99)
		var state:=retry_state()
		var result: Dictionary=items.inventory_command(character,"move",retry_uid(id),0,25,"exhausted-"+code)
		assert(result.error=="storage" and not items.committed and not items.receipt_replay and not pg.in_transaction() and retry_state()==state)
		assert(item_attempts()==(3 if code in ["40001","40P01"] else 1))
		clear_item_retry("receipt")
	for code: String in ["40001","40P01"]:
		item_retry_fault("receipt","move",retry_uid(id),code,99,true)
		var state:=retry_state()
		var result: Dictionary=items.inventory_command(character,"move",retry_uid(id),0,25,"unknown-"+code)
		assert(result.get("outcome_unknown",false) and not items.committed and not items.receipt_replay and not pg.is_open())
		assert(pg.open("postgresql",connection) and item_attempts()==1)
		clear_item_retry("receipt")
		assert(retry_state()==state and items.inventory_receipt(character,"unknown-"+code).error=="unknown_command")
	# A receipted no-op remains a no-op, even when its receipt write is retried.
	var before: Dictionary=items.inventory(character)
	item_retry_fault("receipt","move",retry_uid(id),"40001",1)
	var noop: Dictionary=items.inventory_command(character,"move",retry_uid(id),0,0,"retry-noop")
	assert(noop.ok and not items.committed and not items.receipt_replay and item_attempts()==2 and items.inventory(character)==before)
	assert(items.inventory_command(character,"move",retry_uid(id),0,0,"retry-noop")==noop and not items.committed and items.receipt_replay and item_attempts()==2)
	clear_item_retry("receipt")
	for scenario: String in ["revision","equipment","capacity"]: await retry_reselection(items,scenario)
	print("POSTGRES_INVENTORY_RETRY_OK complete move/equip/activate/unequip/swap, revisions/stats/custody, replay/no-op flags, bounded attempts, no COMMIT retry and current equipment/capacity")

func retry_uid(id: int) -> String: return str(id).pad_zeros(32)

func retry_seed(items: RefCounted, character: int, id: int, equipped: bool) -> void:
	assert(items.bind_character(character,8300) and pg.begin())
	for index: int in 3:
		var item:=prepared(ItemDefinitions.UPGRADE_ORE if index==2 else ItemDefinitions.IRON_SWORD,character,id+index)
		if index==1: item.upgrade_level=1
		assert(items.receive_item_in_transaction(item,index*10).ok)
	assert(pg.commit())
	if equipped: assert(items.inventory_command(character,"equip",retry_uid(id),0,-1,"seed-"+str(id)).ok)

func retry_state() -> Array:
	var state: Array=[]
	for table: String in ["item_instances","item_custody","account_item_revisions","market_commands","ground_item_claims","item_initializations"]:
		var result: Dictionary=pg.query("SELECT row_to_json(t)::text AS value FROM economy."+table+" t ORDER BY row_to_json(t)::text;",{},10000)
		assert(result.ok and not result.truncated)
		state.append(result.rows)
	return state

func item_retry_table(stage: String) -> String:
	return {"placement":"item_custody","revision":"item_instances","receipt":"market_commands"}[stage]

func item_retry_fault(stage: String, action: String, uid: String, code: String, failures: int, deferred: bool = false) -> void:
	assert(pg.execute("ALTER SEQUENCE economy.fixture_item_attempt RESTART WITH 1;").ok)
	var event: String="INSERT" if stage=="receipt" or (stage=="placement" and action!="move") else "UPDATE"
	var create: String="CREATE CONSTRAINT TRIGGER fixture_retry AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED" if deferred else "CREATE TRIGGER fixture_retry BEFORE %s ON economy.%s" % [event,item_retry_table(stage)]
	var condition: String="" if stage=="receipt" else " WHEN (NEW.uid='%s')" % uid
	assert(pg.execute(create+" FOR EACH ROW"+condition+" EXECUTE FUNCTION economy.fixture_item_retry('%s','%d');" % [code,failures]).ok)

func clear_item_retry(stage: String) -> void:
	assert(pg.execute("DROP TRIGGER fixture_retry ON economy."+item_retry_table(stage)+";").ok)

func item_attempts() -> int:
	return int(pg.query("SELECT last_value FROM economy.fixture_item_attempt;").rows[0].last_value)

func retry_reselection(items: RefCounted, scenario: String) -> void:
	var index: int=["revision","equipment","capacity"].find(scenario)
	var character: int=83910+index
	var id: int=21000+index*3
	retry_seed(items,character,id,scenario!="revision")
	var action: String="unequip" if scenario=="capacity" else "equip"
	var target: int=id+1 if scenario=="equipment" else id
	var revision: int=1 if scenario=="capacity" else 0
	var destination: int=25 if scenario=="capacity" else -1
	assert(pg.execute("ALTER SEQUENCE economy.fixture_item_attempt RESTART WITH 1;").ok)
	assert(pg.execute("CREATE TRIGGER fixture_retry BEFORE INSERT ON economy.market_commands FOR EACH ROW WHEN (current_setting('application_name')='retry-inventory') EXECUTE FUNCTION economy.fixture_item_retry('40001','1','gate');").ok)
	assert(pg.execute("SELECT pg_advisory_lock(95129);").ok)
	# Only these coordinated diagnostic sessions extend their timeout budgets.
	var budgets: String=" options='-c statement_timeout=10000 -c lock_timeout=8000 -c idle_in_transaction_session_timeout=10000'"
	var ready:=Semaphore.new()
	var actor:=Thread.new()
	var command_id: String="reselect-"+scenario
	assert(actor.start(item_worker.bind(connection+" application_name=retry-inventory"+budgets,character,action,retry_uid(target),revision,destination,command_id,ready))==OK)
	ready.wait()
	var acting: bool=await item_waiting("retry-inventory")
	var editor:=Thread.new()
	var other_action: String="unequip" if scenario=="equipment" else "move"
	var other_target: int=id+2 if scenario=="capacity" else id
	var other_revision: int=1 if scenario=="equipment" else 0
	var blocked: int=InventoryGrid.cells(25,ItemDefinitions.IRON_SWORD.inventory_height).back()
	assert(editor.start(item_worker.bind(connection+" application_name=retry-inventory-editor"+budgets,character,other_action,retry_uid(other_target),other_revision,blocked if scenario=="capacity" else 25,"edit-"+scenario,ready))==OK)
	ready.wait()
	var editing: bool=await item_waiting("retry-inventory-editor")
	assert(pg.execute("SELECT pg_advisory_unlock(95129);").ok)
	var acted: Dictionary=actor.wait_to_finish()
	var edited: Dictionary=editor.wait_to_finish()
	clear_item_retry("receipt")
	assert(acting and editing and edited.result.ok and edited.committed)
	var inventory: Dictionary=items.inventory(character)
	if scenario=="equipment":
		assert(acted.result.ok and acted.committed and item_attempts()==2 and inventory.equipment.weapon==retry_uid(target))
		assert(inventory.items.any(func(item: Dictionary) -> bool: return item.uid==retry_uid(id) and item.location=="bag" and item.bag_position==25 and item.revision==2),"retry must not move the formerly equipped item a second time")
	else:
		assert(acted.result.error==("stale" if scenario=="revision" else "occupied") and not acted.committed and not acted.replay and item_attempts()==1)
		assert(items.inventory_receipt(character,command_id).error=="unknown_command")
		if scenario=="revision": assert(inventory.items.any(func(item: Dictionary) -> bool: return item.uid==retry_uid(id) and item.location=="bag" and item.bag_position==25 and item.revision==1))
		else: assert(inventory.items.any(func(item: Dictionary) -> bool: return item.uid==retry_uid(id) and item.location=="equipment" and item.revision==1))

func item_waiting(label: String) -> bool:
	var deadline: int=Time.get_ticks_msec()+2000
	while Time.get_ticks_msec()<deadline:
		assert(pg.execute("SELECT pg_stat_clear_snapshot();").ok)
		if int(pg.query("SELECT COUNT(*) AS n FROM pg_stat_activity WHERE application_name=:label AND wait_event_type='Lock';",{"label":label}).rows[0].n)==1: return true
		await get_tree().create_timer(0.005).timeout
	return false

func item_worker(dsn: String, character: int, action: String, uid: String, revision: int, position: int, command_id: String, ready: Semaphore) -> Dictionary:
	var database: Object=ClassDB.instantiate("GodotSociDatabase")
	var opened: bool=database.open("postgresql",dsn)
	ready.post()
	if not opened: return {"result":{"ok":false,"error":"fixture_connection"},"committed":false,"replay":false}
	var store:=PgItems.new(database)
	var result: Dictionary=store.inventory_command(character,action,uid,revision,position,command_id)
	var committed: bool=store.committed
	var replay: bool=store.receipt_replay
	database.close()
	return {"result":result,"committed":committed,"replay":replay}
