extends Node
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Store = preload("res://source/server/world/database/postgres/player_trade_store_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
class LostCommit extends RefCounted:
	var inner: Object
	func _init() -> void:
		inner=ClassDB.instantiate("GodotSociDatabase")
		assert(inner.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
	func begin() -> bool: return inner.begin()
	func commit() -> bool:
		inner.commit();return false
	func rollback() -> bool: return inner.rollback()
	func close() -> void: inner.close()
	func in_transaction() -> bool: return inner.in_transaction()
	func query(sql: String,p: Dictionary={},limit: int=100000) -> Dictionary: return inner.query(sql,p,limit)
	func execute(sql: String,p: Dictionary={}) -> Dictionary: return inner.execute(sql,p)
var db: Object
var contexts: Array=[]
func balance(account: int) -> int: return Wallet.new(db).load_wallet(account).balance
func seed_item(owner: int, definition: ItemDefinition, position: int, affixes: Array=[]) -> String:
	var item:=ItemInstance.create(definition,owner,affixes)
	assert(db.begin() and Items.new(db).receive_item_in_transaction(item,position).ok and db.commit())
	return item.uid
func line(uid: String) -> Dictionary:
	var row: Dictionary=db.query("SELECT revision FROM economy.item_instances WHERE uid=:uid;",{"uid":uid}).rows[0]
	return {"uid":uid,"revision":int(row.revision)}
func pair(a: Array, b: Array, money_a: int=0, money_b: int=0) -> Array:
	return [{"context":contexts[0],"items":a,"yang":money_a,"income":7,"token":"a".repeat(32)},{"context":contexts[1],"items":b,"yang":money_b,"income":5,"token":"b".repeat(32)}]
func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	db=ClassDB.instantiate("GodotSociDatabase")
	assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and Schema.ensure_schema(db))
	for account: int in [11000,11001]:
		assert(Wallet.new(db).initialize_account(account).ok and Items.new(db).bind_character(account*10,account))
		var installed: Dictionary=Sessions.new(db).install_verified_grant(Sessions.identity_from_verified_ticket(account,account*10,"trade-%d"%account),0)
		assert(installed.ok)
		contexts.append(installed.context)
		assert(Sessions.new(db).finish_recovery(installed.context,Commands.read_state(db,account*10)).ok)
	assert(db.execute("UPDATE economy.account_wallets SET yang=1000;").ok)
	var sword:=seed_item(110000,ItemDefinitions.IRON_SWORD,0,[{"stat":"attack","value":7}])
	var ore:=seed_item(110010,ItemDefinitions.UPGRADE_ORE,0)
	var body:=pair([line(sword)],[line(ore)],100,20)
	var store:=Store.new(db)
	var result: Dictionary=store.execute("trade-test",body)
	assert(result.ok and store.committed,JSON.stringify(result))
	assert(balance(11000)==927 and balance(11001)==1085,"pending prefixes and reciprocal Yang conserve units")
	var row: Dictionary=db.query("SELECT * FROM economy.item_instances WHERE uid=:uid;",{"uid":sword}).rows[0]
	assert(row.owner_character_id==110010 and JSON.parse_string(row.affixes_json)[0].value==7 and row.revision==1,"same UID retains rolls and advances revision")
	assert(Store.new(db).execute("trade-test",body).ok and balance(11000)==927,"replay cannot apply pending income twice")
	assert(Store.new(db).receipt(contexts[1],"trade-test").ok,"both participants own a durable outcome")
	var conflict:=body.duplicate(true);conflict[0].yang=99
	assert(Store.new(db).execute("trade-test",conflict).error=="command_conflict")
	assert(Store.new(db).execute("trade-stale",pair([line(sword)],[])).error=="item_changed")
	assert(Store.new(db).execute("trade-funds",pair([],[],999999)).error=="funds")
	assert(balance(11000)==927,"failed settlement rolls back captured income")
	# Abort after the first real item move. Neither ownership, Yang nor receipts survive.
	assert(db.execute("CREATE FUNCTION economy.reject_trade() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'trade fixture rollback'; END $$;").ok)
	assert(db.execute("CREATE TRIGGER reject_trade BEFORE INSERT ON economy.item_custody FOR EACH ROW EXECUTE FUNCTION economy.reject_trade();").ok)
	assert(not Store.new(db).execute("trade-rollback",pair([line(ore)],[line(sword)],1)).ok)
	assert(balance(11000)==927 and Store.new(db).receipt(contexts[0],"trade-rollback").error=="not_committed")
	assert(db.query("SELECT owner_character_id FROM economy.item_instances WHERE uid=:uid;",{"uid":sword}).rows[0].owner_character_id==110010)
	assert(db.execute("DROP TRIGGER reject_trade ON economy.item_custody;").ok and db.execute("DROP FUNCTION economy.reject_trade();").ok)
	# Real competing native workers: a UID can leave its owner only once.
	var executor:=Executor.new()
	assert(executor.start(OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION"),2,2))
	while not executor.is_ready(): executor.poll();await get_tree().process_frame
	body=pair([line(ore)],[])
	var first: Dictionary=executor.submit_trade(contexts[0],"trade-race-a",body)
	var second: Dictionary=executor.submit_trade(contexts[0],"trade-race-b",body)
	assert(first.queued and second.queued)
	var events: Array=[]
	var deadline:=Time.get_ticks_msec()+8000
	while events.size()<2 and Time.get_ticks_msec()<deadline:
		events.append_array(executor.poll());await get_tree().process_frame
	assert(events.size()==2 and events.filter(func(e: Dictionary)->bool:return e.result.get("ok",false)).size()==1,"one winner for a concurrently offered UID")
	executor.begin_drain()
	while not executor.is_stopped(): executor.poll();await get_tree().process_frame
	# Completely full bags can exchange whole stacks because outgoing footprints are freed.
	assert(db.begin() and db.execute("DELETE FROM economy.item_custody;").ok and db.execute("DELETE FROM economy.item_instances;").ok and db.commit())
	var seeds: Array=[]
	for owner: int in [110000,110010]:
		var offered_uids: Array=[]
		for position: int in InventoryGrid.CAPACITY:
			var uid:=seed_item(owner,ItemDefinitions.UPGRADE_ORE,position)
			if position<20: offered_uids.append(uid)
		seeds.append(offered_uids)
	var a_lines: Array=seeds[0].map(func(uid: String)->Dictionary:return line(uid))
	var b_lines: Array=seeds[1].map(func(uid: String)->Dictionary:return line(uid))
	var wire: Dictionary={"action":"offer","trade_id":"trade-"+"a".repeat(32),"version":1,"items":a_lines.map(func(i: Dictionary)->Dictionary:return {"uid":i.uid,"revision":str(i.revision)}),"yang":"0"}
	assert(preload("res://source/common/gameplay/trade/player_trade_contract.gd").valid(wire),"all 20 slots fit the wire limit")
	wire.items.append({"uid":"f".repeat(32),"revision":"0"})
	assert(not preload("res://source/common/gameplay/trade/player_trade_contract.gd").valid(wire),"21st item rejected")
	assert(Store.new(db).execute("trade-full-swap",pair(a_lines,b_lines)).ok,"twenty items per side swap atomically")
	assert(Store.new(db).execute("trade-full-reject",pair([line(seeds[1][0])],[])).error=="inventory_full")
	# Successful COMMIT with a lost acknowledgement: recover, never re-execute.
	var before_a: int=balance(11000)
	var lost: Dictionary=Store.new(LostCommit.new()).execute("trade-lost-commit",pair([],[],1))
	assert(lost.get("outcome_unknown",false))
	assert(balance(11000)==before_a+6)
	assert(Store.new(db).recover("trade-lost-commit",[11000,11001]).ok)
	assert(Store.new(db).receipt(contexts[1],"trade-lost-commit").ok and balance(11000)==before_a+6)
	# A real deferred COMMIT failure has no durable success on either side.
	assert(db.execute("CREATE FUNCTION economy.reject_trade_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'deferred trade fixture'; END $$;").ok)
	assert(db.execute("CREATE CONSTRAINT TRIGGER reject_trade_commit AFTER UPDATE ON economy.account_wallets DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.reject_trade_commit();").ok)
	var connection: Object=ClassDB.instantiate("GodotSociDatabase")
	assert(connection.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
	var failed: Dictionary=Store.new(connection).execute("trade-failed-commit",pair([],[],1))
	assert(failed.get("outcome_unknown",false))
	assert(balance(11000)==before_a+6 and Store.new(db).recover("trade-failed-commit",[11000,11001]).get("resolved",false))
	assert(db.execute("DROP TRIGGER reject_trade_commit ON economy.account_wallets;").ok and db.execute("DROP FUNCTION economy.reject_trade_commit();").ok)
	# Explicit session takeover fences a previously confirmed attempt.
	var replaced: Dictionary=Sessions.new(db).install_verified_grant(Sessions.identity_from_verified_ticket(11000,110000,"new-trade-session"),1)
	assert(replaced.ok)
	assert(Store.new(db).execute("trade-old-session",pair([],[],1)).error=="stale_session")
	assert(db.query("SELECT COUNT(*) AS n FROM economy.item_instances;").rows[0].n==InventoryGrid.CAPACITY*2,"no item duplication or loss")
	db.close()
	print("POSTGRES_PLAYER_TRADE_OK: atomic UIDs/Yang, dual receipts, replay/conflict, failure rollback, native race, full bags and session fence")
	get_tree().quit()
