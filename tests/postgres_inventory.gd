extends Node
## Opt-in native PostgreSQL / migrated SQLite behavior parity. Owned fixtures only.
const Schema = preload("res://source/server/world/database/postgres/inventory_schema_postgres.gd")
const PgItems = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const PgWallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var sqlite: SQLite
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
	sqlite=SQLite.new()
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
	pg.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(sqlite.path+suffix))
	print("POSTGRES_INVENTORY_OK SQLite parity: starter/pickup, move/equip/swap/activate/unequip, stats, receipts, reopen, full bag and atomic failures")
	get_tree().quit()
