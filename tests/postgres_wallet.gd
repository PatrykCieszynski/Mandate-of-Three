extends Node
## Opt-in native backend parity. Existing yang_wallet keeps runtime RAM/checkpoint
## coverage; this fixture compares durable behavior against that production store.
const PgSchema = preload("res://source/server/world/database/postgres/wallet_schema_postgres.gd")
const PgWallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var sqlite: SQLite
var postgres: Object
var directory: String
var account: int
var other_account: int
var capped_account: int

func sql(pg: bool, statement: String) -> bool:
	return postgres.execute(statement).ok if pg else sqlite.query(statement)

func begin(pg: bool) -> bool:
	return postgres.begin() if pg else sqlite.query("BEGIN IMMEDIATE;")

func rollback(pg: bool) -> bool:
	return postgres.rollback() if pg else sqlite.query("ROLLBACK;")

func state(wallet: RefCounted, owner: int) -> Dictionary:
	var result: Dictionary = wallet.load_wallet(owner)
	assert(result.ok)
	var value: Dictionary = result.wallet_state.duplicate(true)
	assert(preload("res://source/common/gameplay/items/domain/wallet_state_version.gd").valid(value))
	value.erase("authority_id") # Each independent backend owns a different identity.
	return value

func exercise(wallet: RefCounted, pg: bool) -> Array:
	var results: Array = []
	var table := "economy.account_wallets" if pg else "account_wallets"
	assert(wallet.load_wallet(999999).error == "owner")
	assert(state(wallet, account).balance == 1500)
	assert(wallet.checkpoint({}).ok)
	results.append(state(wallet, account))
	assert(wallet.checkpoint({account:90, other_account:38500}).ok)
	assert(state(wallet, account).balance == 1590 and state(wallet, other_account).balance == 40000)
	results.append(state(wallet, account))
	var before := state(wallet, other_account)
	# Failure AFTER pending income, BEFORE spending. Balance and revision roll back.
	if pg:
		assert(sql(pg,"CREATE FUNCTION economy.fixture_reject_wallet() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'wallet fixture fault'; END; $$;"))
		assert(sql(pg,"CREATE TRIGGER fixture_fault BEFORE UPDATE ON %s FOR EACH ROW WHEN (NEW.yang<OLD.yang) EXECUTE FUNCTION economy.fixture_reject_wallet();" % table))
	else:
		assert(sql(pg,"CREATE TEMP TRIGGER fixture_fault BEFORE UPDATE ON %s WHEN NEW.yang<OLD.yang BEGIN SELECT RAISE(ABORT,'wallet fixture fault'); END;" % table))
	assert(not wallet.spend(other_account,30000,50000).ok)
	assert(state(wallet, other_account)==before, "pending income and revision must roll back together")
	assert(sql(pg,"DROP TRIGGER fixture_fault ON %s;" % table if pg else "DROP TRIGGER fixture_fault;"))
	var spent: Dictionary = wallet.spend(other_account,30000,50000)
	assert(spent.ok and spent.balance==20000 and spent.wallet_state.pending_applied==30000)
	results.append(state(wallet, other_account))
	before = state(wallet, other_account)
	assert(wallet.spend(other_account,0,20001).error=="funds")
	assert(wallet.spend(other_account,-1,1).error=="request")
	assert(wallet.spend(other_account,0,0).error=="request")
	assert(state(wallet, other_account)==before)
	# A later failure in the surrounding use case rolls back spend AND income.
	assert(begin(pg))
	assert(wallet.spend_in_transaction(other_account,27,100).ok)
	assert(not sql(pg,"UPDATE %s SET reserved_yang=yang+1 WHERE account_id=%d;" % [table,other_account]))
	assert(rollback(pg))
	assert(state(wallet, other_account)==before)
	# The credit primitive also belongs to that same transaction owner.
	assert(begin(pg))
	assert(wallet.credit_in_transaction(other_account,8,50).ok)
	assert(rollback(pg))
	assert(state(wallet, other_account)==before)
	var credited: Dictionary = wallet.credit(other_account,8,50)
	assert(credited.ok and credited.balance==20058 and credited.wallet_state.pending_applied==8)
	results.append(state(wallet, other_account))
	# Reservations cannot be spent. Pending income is included atomically once.
	assert(sql(pg,"UPDATE %s SET reserved_yang=yang-5 WHERE account_id=%d;" % [table,other_account]))
	before = state(wallet, other_account)
	assert(wallet.spend(other_account,0,6).error=="funds")
	assert(state(wallet, other_account)==before)
	assert(wallet.spend(other_account,2,6).ok)
	results.append(state(wallet, other_account))
	# Zero delta must not manufacture a new wallet revision.
	before = state(wallet, account)
	assert(wallet.checkpoint({account:0}).ok)
	assert(state(wallet, account)==before)
	# Absolute durable change followed by a delta preserves both contributions.
	assert(sql(pg,"UPDATE %s SET yang=yang+7 WHERE account_id=%d;" % [table,account]))
	assert(wallet.checkpoint({account:10}).ok)
	assert(state(wallet, account).balance==1607)
	results.append(state(wallet, account))
	# Every dirty account is one transaction: a later cap violation rolls back
	# the first account, including its revision. Exact BIGINT cap survives reload.
	assert(wallet.checkpoint({capped_account:PgWallet.MAX_YANG-1500}).ok)
	before = state(wallet, account)
	assert(not wallet.checkpoint({account:13,capped_account:1}).ok)
	assert(state(wallet, account)==before)
	assert(state(wallet, capped_account).balance==PgWallet.MAX_YANG)
	assert(not wallet.credit(capped_account,0,1).ok)
	assert(wallet.credit(account,0,0).error=="request")
	assert(not wallet.checkpoint({account:5,999999:1}).ok)
	assert(state(wallet, account)==before)
	results.append(state(wallet, capped_account))
	return results

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster", "Use the owned PostgreSQL runner")
	directory=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	assert(directory.begins_with("res://.godot/verification/postgres-readiness/run-") and not ".." in directory)
	sqlite=SQLite.new()
	sqlite.path=directory+"/wallet-parity.db"
	assert(not FileAccess.file_exists(sqlite.path) and sqlite.open_db())
	WorldSchema.ensure_schema(sqlite)
	var world_store:=WorldStoreSqlite.new(sqlite)
	var character:=EconomyFixture.create_character(world_store,"pg-wallet-a",{"name":"A","skin":1})
	var alt:=EconomyFixture.create_character(world_store,"pg-wallet-a",{"name":"Alt","skin":1})
	var other:=EconomyFixture.create_character(world_store,"pg-wallet-b",{"name":"B","skin":1})
	var capped:=EconomyFixture.create_character(world_store,"pg-wallet-c",{"name":"C","skin":1})
	var runtime:=WorldDatabase.new()
	runtime.db=sqlite
	runtime.store=world_store
	EconomyFixture.prepare(runtime)
	account=world_store.resolve_account_id(character)
	other_account=world_store.resolve_account_id(other)
	capped_account=world_store.resolve_account_id(capped)
	assert(account>0 and account==world_store.resolve_account_id(alt), "Master identity gives alts one account wallet")
	postgres=ClassDB.instantiate("GodotSociDatabase")
	var connection:=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	assert(postgres.open("postgresql",connection))
	assert(postgres.query("SELECT current_database() AS db,current_user AS role;").rows[0]=={"db":"mandate_readiness","role":"mandate_fixture"})
	assert(PgSchema.ensure_schema(postgres))
	var pg_wallet:=PgWallet.new(postgres)
	for owner: int in [account,other_account,capped_account]: assert(pg_wallet.initialize_account(owner).ok)
	var authority: String = pg_wallet.load_wallet(account).wallet_state.authority_id
	assert(PgSchema.ensure_schema(postgres) and pg_wallet.load_wallet(account).wallet_state.authority_id==authority)
	var sqlite_results:=exercise(WalletStoreSqlite.new(sqlite),false)
	var pg_results:=exercise(pg_wallet,true)
	assert(sqlite_results==pg_results, "same durable balances/reservations/revisions as SQLite")
	var before:=state(pg_wallet,account)
	assert(pg_wallet.initialize_account(account).ok and state(pg_wallet,account)==before, "no repeat starting grant")
	assert(postgres.begin())
	assert(not pg_wallet.spend(account,0,1).ok and postgres.in_transaction(), "standalone operation cannot steal caller transaction")
	assert(postgres.rollback())
	assert(pg_wallet.spend_in_transaction(account,0,1).error=="transaction")
	assert(pg_wallet.credit_in_transaction(account,0,1).error=="transaction")
	# Native COMMIT-error handling is isolated in postgres_commit_failure: the
	# pinned Windows driver currently exits before GDScript can inspect its result.
	postgres.close()
	assert(postgres.open("postgresql",connection) and PgSchema.ensure_schema(postgres))
	assert(pg_wallet.load_wallet(account).wallet_state.authority_id==authority and state(pg_wallet,account)==before)
	assert(sqlite.close_db() and sqlite.open_db())
	assert(state(WalletStoreSqlite.new(sqlite),account)==before)
	# Do not silently run new code against an unknown future wallet migration.
	assert(postgres.execute("UPDATE economy.schema_versions SET version=2 WHERE feature='wallet';").ok)
	assert(not PgSchema.ensure_schema(postgres))
	assert(state(pg_wallet,account)==before)
	postgres.close()
	runtime.db=null
	runtime.free()
	sqlite.close_db()
	for suffix: String in ["","-wal","-shm"]: DirAccess.remove_absolute(ProjectSettings.globalize_path(sqlite.path+suffix))
	print("POSTGRES_WALLET_OK SQLite parity: account scope, delta/checkpoint, atomic spend/credit, reservations, rollback, revisions, cap and reconnect")
	get_tree().quit()
