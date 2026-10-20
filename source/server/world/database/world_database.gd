class_name WorldDatabase
extends Node


signal experience_awarded(owner_id: int, amount: int, levels_gained: int, level: int)

func award_experience(player: PlayerResource, amount: int) -> void:
	if player == null or amount <= 0: return
	var result: Dictionary = player.add_experience(amount)
	mark_progression_dirty(player)
	experience_awarded.emit(player.player_id,amount,int(result.levels_gained),int(result.level))

var economy_backend: String="sqlite" # Explicit bootstrap selection; never auto-fallback.
var database_path: String
var db: SQLite
var store: WorldStoreSqlite
var mail_store: MailStore
var item_store: ItemStoreSqlite
var wallet_store: WalletStoreSqlite
const WALLET_SAVE_SECONDS: float = 30.0
# Wallet RAM/dirty keys are global Master account IDs within this World.
var runtime_wallets: Dictionary[int, Dictionary] = {}
var _wallet_accounts: Dictionary[int, int] = {}
var wallet_ready := false
var _wallet_reconciliation_failed := false
var _economy_identity := ""
var auction_queries: AuctionQueryService
var _auction_lifecycle_busy := false
var _auction_quiesced := false

func auction_binding_current() -> bool:
	if db==null: return false
	var wanted:=ProjectSettings.globalize_path(database_path if not database_path.is_empty() else db.path)
	return auction_queries!=null and auction_queries.writer==db and auction_queries.path==wanted

func start_auction_queries() -> bool:
	if economy_backend!="sqlite": return false
	if not wallet_ready or db==null: return false
	if auction_queries==null:
		auction_queries=AuctionQueryService.new();add_child(auction_queries)
		auction_queries.recovery_allowed=func()->bool:return wallet_ready and not _auction_quiesced and auction_binding_current()
	var wanted:=ProjectSettings.globalize_path(database_path if not database_path.is_empty() else db.path)
	if auction_queries.admissions:
		var current:=auction_binding_current()
		if not current: auction_queries.admissions=false
		return current
	_auction_quiesced=false
	return await auction_queries.start(db,wanted)

func coordinated_backup(keep_last: int = 10, restart_reader: bool = true, final_flush: bool = false) -> bool:
	if _auction_lifecycle_busy: return false
	_auction_lifecycle_busy=true
	var had_reader:=auction_queries!=null
	if had_reader and not await auction_queries.pause():
		_auction_lifecycle_busy=false;return false
	var ok:=flush_character() if final_flush else true
	if ok: ok=backup_database(keep_last)
	if had_reader and restart_reader and not _auction_quiesced and not await start_auction_queries(): ok=false
	if ok and not restart_reader: _auction_quiesced=true
	_auction_lifecycle_busy=false
	return ok

func shutdown_database() -> bool:
	if not await coordinated_backup(10,false,true): return false
	wallet_ready=false
	_economy_identity = ""
	return db!=null and db.close_db()

func economic_context(character_id: int) -> Dictionary:
	if economy_backend!="sqlite": return {}
	if db == null or character_id <= 0: return {}
	if _economy_identity.is_empty():
		if not db.query("SELECT value FROM meta WHERE key='economy_authority_id';") or db.query_result.is_empty(): return {}
		var value := str(db.query_result[0].value)
		if not ItemInstance.valid_uid(value): return {}
		_economy_identity = value
	var account := wallet_account_id(character_id)
	if account <= 0: return {}
	return {"authority_id":_economy_identity,"account_id":account,"character_id":character_id}

func wallet_account_id(character_id: int) -> int:
	if not _wallet_accounts.has(character_id) and store != null:
		var account_id := store.resolve_account_id(character_id)
		if account_id > 0: _wallet_accounts[character_id] = account_id
	return _wallet_accounts.get(character_id,0)

func prepare_account_wallets(master_ids: Dictionary) -> Dictionary:
	if economy_backend!="sqlite": return {"ok":false,"error":"backend"}
	if _wallet_reconciliation_failed: return {"ok":false,"error":"wallet_reconciliation"}
	var result := WorldSchema.migrate_account_wallets(db,master_ids)
	if result.ok and not MarketStoreSqlite.ensure_schema(db): result = {"ok":false,"error":"market_custody_migration"}
	if result.ok and not MarketSearchSqlite.ensure_schema(db): result = {"ok":false,"error":"market_search_migration"}
	if result.ok and not ExchangeStoreSqlite.ensure_ledger_schema(db): result = {"ok":false,"error":"exchange_ledger_migration"}
	if result.ok and not ExchangeStoreSqlite.ensure_orders_schema(db): result = {"ok":false,"error":"exchange_orders_migration"}
	if result.ok and not MarketSearchSqlite.ensure_lookup_schema(db): result = {"ok":false,"error":"market_lookup_migration"}
	if result.ok and not MarketStoreSqlite.ensure_offer_only_schema(db): result = {"ok":false,"error":"market_offer_only_migration"}
	wallet_ready = result.ok
	return result

## Server-only durable credit; online pending income shares the same commit.
func credit_account(account_id: int, amount: int) -> Dictionary:
	if economy_backend!="sqlite": return {"ok":false,"error":"backend"}
	if not wallet_ready or wallet_store == null: return {"ok":false,"error":"storage"}
	var pending := int(runtime_wallets.get(account_id,{}).get("pending_currency_delta",0))
	var result := wallet_store.credit(account_id,pending,amount)
	if result.ok and runtime_wallets.has(account_id):
		reconcile_committed_wallet(result.wallet_state)
	return result
var dirty_wallet: Dictionary[int, bool] = {}
var _wallet_elapsed: float = 0.0
const PROGRESSION_SAVE_SECONDS: float = 60.0
var dirty_progression: Dictionary[int, PlayerResource] = {}
var _progression_elapsed: float = 0.0

func pending_progression_player(owner_id: int, fallback: PlayerResource = null) -> PlayerResource:
	# RAM-only query for offline rewards/reentry. Never loads stale SQL state.
	return dirty_progression.get(owner_id,fallback)

func mark_progression_dirty(player: PlayerResource) -> void:
	dirty_progression[player.player_id] = player

func flush_progression(owner_id: int = -1) -> bool:
	var players: Array[PlayerResource] = []
	for id: int in dirty_progression:
		if owner_id < 0 or id == owner_id: players.append(dirty_progression[id])
	if players.is_empty(): return true
	if store == null or not store.save_progression(players): return false
	for player: PlayerResource in players: dirty_progression.erase(player.player_id)
	return true

func load_wallet(character_id: int) -> bool:
	if economy_backend!="sqlite": return false
	var owner_id := wallet_account_id(character_id)
	if not wallet_ready or owner_id <= 0: return false
	if runtime_wallets.has(owner_id): return true
	if wallet_store == null:
		if db == null: return false
		wallet_store = WalletStoreSqlite.new(db)
	var result: Dictionary = wallet_store.load_wallet(owner_id)
	if not result.ok: return false
	runtime_wallets[owner_id] = {"wallet_balance": int(result.balance), "pending_currency_delta": 0,"reserved_yang":int(result.get("reserved_yang",0)),"durable_balance":int(result.balance),"wallet_state":result.wallet_state.duplicate(true)}
	return true

func wallet_balance(character_id: int) -> int:
	if economy_backend!="sqlite": return -1
	var owner_id := wallet_account_id(character_id)
	return int(runtime_wallets.get(owner_id, {}).get("wallet_balance", -1))

func wallet_available(character_id: int) -> int:
	var account:=wallet_account_id(character_id)
	return wallet_balance(character_id)-int(runtime_wallets.get(account,{}).get("reserved_yang",0))

func add_yang(character_id: int, amount: int) -> bool:
	if economy_backend!="sqlite": return false
	var owner_id := wallet_account_id(character_id)
	if not wallet_ready or not runtime_wallets.has(owner_id) or amount <= 0: return false
	var wallet: Dictionary = runtime_wallets[owner_id]
	if amount > WalletStoreSqlite.MAX_YANG - int(wallet.wallet_balance): return false
	wallet.wallet_balance += amount
	wallet.pending_currency_delta += amount
	dirty_wallet[owner_id] = true
	return true

func flush_wallet(character_id: int = -1) -> bool:
	var runtime:=_postgres_wallet_runtime()
	if runtime!=null:
		if character_id<0:
			runtime.checkpoint_all()
			return runtime.drained()
		return runtime.checkpoint(WorldServer.curr.player_id_to_peer_id.get(character_id,0))
	if economy_backend!="sqlite": return dirty_wallet.is_empty()
	if not wallet_ready: return dirty_wallet.is_empty()
	var owner_id := wallet_account_id(character_id) if character_id >= 0 else -1
	if character_id >= 0 and owner_id <= 0: return false
	var deltas: Dictionary = {}
	for id: int in dirty_wallet:
		if owner_id < 0 or id == owner_id:
			deltas[id] = int(runtime_wallets[id].pending_currency_delta)
	if deltas.is_empty(): return true
	if wallet_store == null: return false
	var result: Dictionary = wallet_store.checkpoint(deltas)
	if not result.ok: return false
	for state: Dictionary in result.wallet_states:
		reconcile_committed_wallet(state)
	return wallet_ready

func spend_yang(character_id: int, cost: int) -> Dictionary:
	if economy_backend!="sqlite": return {"ok":false,"error":"backend"}
	var owner_id := wallet_account_id(character_id)
	# Affordability is checked against authoritative RAM, including pending income.
	if not wallet_ready or cost <= 0 or not runtime_wallets.has(owner_id): return {"ok": false, "error": "request"}
	var wallet: Dictionary = runtime_wallets[owner_id]
	if wallet_available(character_id) < cost: return {"ok": false, "error": "funds"}
	var result: Dictionary = wallet_store.spend(owner_id, int(wallet.pending_currency_delta), cost)
	if result.ok: reconcile_committed_wallet(result.wallet_state)
	return result

func accept_committed_wallet(state: Dictionary) -> bool:
	# Local post-COMMIT boundary, not a public RPC nor receipt-replay handler.
	var version = preload("res://source/common/gameplay/items/domain/wallet_state_version.gd")
	if not version.valid(state): return false
	var account: int = state.account_id
	if not runtime_wallets.has(account): return true # Offline settlement stays offline.
	var wallet: Dictionary = runtime_wallets[account]
	var current: Dictionary = wallet.wallet_state
	if not version.accepts(current,state): return false
	for key: String in ["balance","reserved_yang","pending_applied"]:
		if not state.get(key) is int: return false
	if state.balance<0 or state.balance>WalletStoreSqlite.MAX_YANG or state.reserved_yang<0 or state.reserved_yang>state.balance or state.pending_applied<0: return false
	if int(state.revision)==int(current.revision):
		return state.balance==wallet.durable_balance and state.reserved_yang==wallet.reserved_yang
	var remaining := int(wallet.pending_currency_delta)-int(state.pending_applied)
	if remaining<0 or remaining>WalletStoreSqlite.MAX_YANG-int(state.balance): return false
	wallet.wallet_state = state.duplicate(true)
	wallet.durable_balance = int(state.balance)
	wallet.wallet_balance = int(state.balance)+remaining
	wallet.reserved_yang = int(state.reserved_yang)
	wallet.pending_currency_delta = remaining
	if remaining>0: dirty_wallet[account]=true
	else: dirty_wallet.erase(account)
	return true

func reconcile_committed_wallet(state: Dictionary) -> void:
	# Execute in release builds too. Never put reconciliation inside assert().
	if accept_committed_wallet(state): return
	var account: int = state.account_id if state.get("account_id") is int else 0
	if runtime_wallets.has(account):
		var current: Dictionary = runtime_wallets[account].wallet_state
		if state.get("authority_id")==current.authority_id and state.get("revision") is int and state.revision<current.revision: return
	# An unexplained new committed state cannot be safely retried from old RAM.
	# Stop monetary writes/checkpoints rather than apply its income twice.
	_wallet_reconciliation_failed = true
	wallet_ready = false
	push_error("Committed wallet state could not be reconciled; monetary writes disabled until restart.")

func wallet_snapshot(character_id: int) -> Dictionary:
	if economy_backend!="sqlite": return {}
	var account := wallet_account_id(character_id)
	if not runtime_wallets.has(account): return {"balance":-1,"wallet_state":{}}
	var wallet: Dictionary = runtime_wallets[account]
	var state: Dictionary = wallet.wallet_state
	return {"balance":int(wallet.wallet_balance),"wallet_state":{"authority_id":state.authority_id,"account_id":account,"revision":int(state.revision)}}

func inventory_receipt(owner_id: int, operation_id: String) -> EconomyOperationResult:
	return _economy().inventory_receipt(owner_id,operation_id)

func inventory_operation(owner_id: int, action: String, uid: String, revision: int, position: int = -1, operation_id: String = "") -> EconomyOperationResult:
	return _economy().inventory_operation(owner_id, action, uid, revision, position, operation_id)

func shop_purchase_receipt(owner_id: int, operation_id: String) -> EconomyOperationResult:
	return _economy().shop_purchase_receipt(owner_id, operation_id)

func purchase_shop_operation(owner_id: int, shop: ShopDefinition, offer_id: StringName, requested_position: int = -1, operation_id: String = "") -> EconomyOperationResult:
	return _economy().purchase_shop_operation(owner_id, shop, offer_id, requested_position, operation_id)

func purchase_shop_offer(owner_id: int, shop: ShopDefinition, offer_id: StringName, requested_position: int = -1, operation_id: String = "") -> Dictionary:
	return purchase_shop_operation(owner_id, shop, offer_id, requested_position, operation_id).response()

func upgrade_candidate(owner_id: int, uid: String, revision: int, recipe: UpgradeDefinition) -> Dictionary:
	return _economy().upgrade_candidate(owner_id, uid, revision, recipe)

func storage_snapshot(owner_id: int) -> Dictionary:
	if economy_backend!="sqlite": return {"ok":false,"error":"backend"}
	if db == null: return {"ok":false,"error":"storage"}
	return AccountStorageSqlite.new(db).snapshot(owner_id)

func market_snapshot(character_id: int) -> Dictionary:
	return _economy().market_snapshot(character_id)

signal market_account_changed(account_id: int)
var _economy_service: WorldEconomyService

func _economy() -> WorldEconomyService:
	if _economy_service == null:
		_economy_service = WorldEconomyService.new(self)
		_economy_service.market_account_changed.connect(market_account_changed.emit)
	return _economy_service

func market_operation(character_id: int, action: String, payload: Dictionary) -> EconomyOperationResult:
	return _economy().market_operation(character_id, action, payload)

func market_command(character_id: int, action: String, payload: Dictionary) -> Dictionary:
	return market_operation(character_id, action, payload).response()

func market_query(character_id: int, action: String, payload: Dictionary) -> Dictionary:
	return _economy().market_query(character_id,action,payload)

func claim_ground_item_operation(owner_id: int, drop_uid: String, item: ItemInstance) -> EconomyOperationResult:
	return _economy().claim_ground_item_operation(owner_id, drop_uid, item)

func storage_receipt(owner_id: int, operation_id: String) -> EconomyOperationResult:
	return _economy().storage_receipt(owner_id,operation_id)

func storage_operation(owner_id: int, uid: String, revision: int, source: String, destination: String, position: int, operation_id: String = "") -> EconomyOperationResult:
	return _economy().storage_operation(owner_id, uid, revision, source, destination, position, operation_id)

func transfer_storage(owner_id: int, uid: String, revision: int, source: String, destination: String, position: int, operation_id: String = "") -> Dictionary:
	return storage_operation(owner_id, uid, revision, source, destination, position, operation_id).response()

func upgrade_receipt(owner_id: int, operation_id: String) -> EconomyOperationResult:
	return _economy().upgrade_receipt(owner_id,operation_id)

func upgrade_operation(owner_id: int, recipe: UpgradeDefinition, uid: String, revision: int, operation_id: String = "") -> EconomyOperationResult:
	return _economy().upgrade_operation(owner_id, recipe, uid, revision, operation_id)

func upgrade_item(owner_id: int, recipe: UpgradeDefinition, uid: String, revision: int, operation_id: String = "") -> Dictionary:
	return upgrade_operation(owner_id, recipe, uid, revision, operation_id).response()

func release_wallet(character_id: int) -> void:
	var owner_id := wallet_account_id(character_id)
	# Failed offline saves remain authoritative until a later successful retry.
	if not dirty_wallet.has(owner_id): runtime_wallets.erase(owner_id)

func flush_character(owner_id: int = -1) -> bool:
	var progression_ok: bool = flush_progression(owner_id)
	var wallet_ok: bool = flush_wallet(owner_id)
	return progression_ok and wallet_ok

func _process(delta: float) -> void:
	_wallet_elapsed += delta
	if _wallet_elapsed >= WALLET_SAVE_SECONDS:
		_wallet_elapsed = fmod(_wallet_elapsed, WALLET_SAVE_SECONDS)
		# The PG owner runs its own ordinary (non-quiescing) 30-second batching.
		# Do not turn that into a forced save through this legacy timer as well.
		if _postgres_wallet_runtime()==null and not flush_wallet(): push_error("Wallet checkpoint failed; pending income retained for retry.")
	_progression_elapsed += delta
	if _progression_elapsed < PROGRESSION_SAVE_SECONDS: return
	_progression_elapsed = fmod(_progression_elapsed, PROGRESSION_SAVE_SECONDS)
	if not flush_progression(): push_error("Progression checkpoint failed; dirty characters retained for retry.")

func _postgres_wallet_runtime() -> RefCounted:
	var world:=WorldServer.curr
	return null if world==null or world.database!=self else world.wallet_runtime


func start_database(world_info: Dictionary) -> void:
	if auction_queries!=null and auction_queries.reader.dispatcher!=null:
		push_error("Database reopen refused: pause/drain auction reader first.")
		return
	configure_database(world_info)
	open_database()
	WorldSchema.ensure_schema(db)
	store = WorldStoreSqlite.new(db)
	mail_store = MailStore.new(db)
	item_store = ItemStoreSqlite.new(db)
	wallet_store = WalletStoreSqlite.new(db)


func configure_database(world_info: Dictionary) -> void:
	var file_name: String = (str(world_info["name"]) + ".db").to_lower()

	# Reminder: writing to res:// is fine in editor, NOT in exports.
	if OS.has_feature("editor"):
		database_path = "res://source/server/world/data/" + file_name
	else:
		database_path = "user://db/" + file_name


func open_database() -> void:
	# Ensure directory exists for user://
	if not OS.has_feature("editor"):
		DirAccess.make_dir_recursive_absolute("user://db")

	db = SQLite.new()
	db.path = database_path

	# Optional: verbosity while you develop
	# db.verbosity_level = SQLite.VerbosityLevel.NORMAL

	db.open_db()
	# One authoritative writer. FULL is the default now that player trading exists;
	# NORMAL remains an explicit development choice, with a larger power-loss window.
	db.query("PRAGMA journal_mode=WAL;")
	var sync_mode: String=str(ProjectSettings.get_setting("mandate/persistence/sqlite_synchronous","FULL"))
	if sync_mode not in ["FULL","NORMAL"]: sync_mode="FULL"
	db.query("PRAGMA synchronous="+sync_mode+";")



func close_database() -> bool:
	return await shutdown_database()


func _notification(what: int) -> void:
	# WorldServer coordinates graceful reader drain and writer close.
	if what == NOTIFICATION_WM_CLOSE_REQUEST: flush_character()


func get_player_resource(id: int) -> PlayerResource:
	if dirty_progression.has(id): return dirty_progression[id]
	return store.get_player(id)


func create_player_character(username: String, character_data: Dictionary) -> int:
	return store.create_player_character(username, character_data)


func get_account_characters(account_name: String) -> Dictionary:
	return store.get_account_characters(account_name)


func get_guild(id: int) -> Guild:
	return store.get_guild(id)


func save_player(p: PlayerResource) -> void:
	# A session/profile save has its own legacy payload. XP checkpoints themselves
	# only use the three-column batch above, never this full serializer.
	flush_character(p.player_id)
	store.save_player(p)


func save_guild(g: Guild) -> void:
	store.save_guild(g)


## Flush every still-connected player to disk. Called from the periodic save
## tick AND from the console's `save` / `shutdown` commands — previously the
## console called a method that didn't exist, so shutdowns silently lost
## anyone who hadn't disconnected yet. Returns the count actually saved.
func save_all_connected(connected_players: Dictionary) -> int:
	# Includes dirty characters whose peers have already disconnected.
	if not flush_character(): return -1
	var count: int = 0
	for peer_id: int in connected_players:
		var p: PlayerResource = connected_players[peer_id]
		if p == null:
			continue
		store.save_player(p)
		count += 1
	return count


## Snapshot the live .db file to user://db_backups/<name>_<unix_ts>.db and
## prune older backups to keep at most [param keep_last]. Returns true on success.
##
## CRITICAL: checkpoint the WAL into the main .db FIRST. In WAL mode recent writes
## live in the -wal sidecar until checkpointed, and this backup byte-copies ONLY the
## .db — so without the checkpoint every backup silently omitted everything since the
## last auto-checkpoint (observed live: a 332 KB .db beside a 4 MB uncheckpointed
## -wal, i.e. hours of progress missing from every "successful" backup). TRUNCATE
## also folds the -wal back to ~0, so the live .db stays current and the -wal can't
## balloon. A reader may prevent truncation; then fail instead of copying a stale DB.
func backup_database(keep_last: int = 10) -> bool:
	# Direct callers may only checkpoint after the native reader has been closed.
	if auction_queries!=null and auction_queries.reader.dispatcher!=null: return false
	if database_path.is_empty():
		return false
	if not FileAccess.file_exists(database_path):
		return false

	if db == null or not db.query("PRAGMA wal_checkpoint(TRUNCATE);") or db.query_result.is_empty() or int(db.query_result[0].get("busy",1))!=0:
		return false

	var backup_dir: String = "user://db_backups"
	DirAccess.make_dir_recursive_absolute(backup_dir)

	var base_name: String = database_path.get_file()
	var name_without_ext: String = base_name.get_basename()
	var unix_ts: int = int(Time.get_unix_time_from_system())
	var backup_path: String = "%s/%s_%d.db" % [backup_dir, name_without_ext, unix_ts]

	var src: FileAccess = FileAccess.open(database_path, FileAccess.READ)
	if src == null:
		return false
	var contents: PackedByteArray = src.get_buffer(src.get_length())
	src.close()

	var dst: FileAccess = FileAccess.open(backup_path, FileAccess.WRITE)
	if dst == null:
		return false
	dst.store_buffer(contents)
	dst.close()

	_rotate_backups(backup_dir, name_without_ext, keep_last)
	return true


func _rotate_backups(backup_dir: String, name_prefix: String, keep_last: int) -> void:
	var dir: DirAccess = DirAccess.open(backup_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var backups: Array[String] = []
	var file: String = dir.get_next()
	while not file.is_empty():
		if not dir.current_is_dir() and file.begins_with(name_prefix + "_") and file.ends_with(".db"):
			backups.append(file)
		file = dir.get_next()
	dir.list_dir_end()
	# Filenames embed the unix timestamp, so lexical sort matches chronological.
	backups.sort()
	while backups.size() > keep_last:
		var to_remove: String = backups.pop_front()
		DirAccess.remove_absolute(backup_dir + "/" + to_remove)
