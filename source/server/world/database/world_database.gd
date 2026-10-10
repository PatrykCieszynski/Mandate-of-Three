class_name WorldDatabase
extends Node


var database_path: String
var db: SQLite
var store: WorldStoreSqlite
var mail_store: MailStore
var item_store: ItemStoreSqlite
var wallet_store: WalletStoreSqlite
const WALLET_SAVE_SECONDS: float = 30.0
var runtime_wallets: Dictionary[int, Dictionary] = {}
var dirty_wallet: Dictionary[int, bool] = {}
var _wallet_elapsed: float = 0.0
const PROGRESSION_SAVE_SECONDS: float = 60.0
var dirty_progression: Dictionary[int, PlayerResource] = {}
var _progression_elapsed: float = 0.0

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

func load_wallet(owner_id: int) -> bool:
	if runtime_wallets.has(owner_id): return true
	if wallet_store == null:
		if db == null: return false
		wallet_store = WalletStoreSqlite.new(db)
	var result: Dictionary = wallet_store.load_wallet(owner_id)
	if not result.ok: return false
	runtime_wallets[owner_id] = {"wallet_balance": int(result.balance), "pending_currency_delta": 0}
	return true

func wallet_balance(owner_id: int) -> int:
	return int(runtime_wallets.get(owner_id, {}).get("wallet_balance", -1))

func add_yang(owner_id: int, amount: int) -> bool:
	if not runtime_wallets.has(owner_id) or amount <= 0: return false
	var wallet: Dictionary = runtime_wallets[owner_id]
	if amount > WalletStoreSqlite.MAX_YANG - int(wallet.wallet_balance): return false
	wallet.wallet_balance += amount
	wallet.pending_currency_delta += amount
	dirty_wallet[owner_id] = true
	return true

func flush_wallet(owner_id: int = -1) -> bool:
	var deltas: Dictionary = {}
	for id: int in dirty_wallet:
		if owner_id < 0 or id == owner_id:
			deltas[id] = int(runtime_wallets[id].pending_currency_delta)
	if deltas.is_empty(): return true
	if wallet_store == null: return false
	var result: Dictionary = wallet_store.checkpoint(deltas)
	if not result.ok: return false
	for id: int in deltas:
		runtime_wallets[id].wallet_balance = int(result.balances[id])
		runtime_wallets[id].pending_currency_delta = 0
		dirty_wallet.erase(id)
	return true

func spend_yang(owner_id: int, cost: int) -> Dictionary:
	# Affordability is checked against authoritative RAM, including pending income.
	if cost <= 0 or not runtime_wallets.has(owner_id): return {"ok": false, "error": "request"}
	var wallet: Dictionary = runtime_wallets[owner_id]
	if int(wallet.wallet_balance) < cost: return {"ok": false, "error": "funds"}
	var result: Dictionary = wallet_store.spend(owner_id, int(wallet.pending_currency_delta), cost)
	if result.ok: accept_committed_wallet_balance(owner_id, int(result.balance))
	return result

func accept_committed_wallet_balance(owner_id: int, balance: int) -> void:
	assert(runtime_wallets.has(owner_id) and balance >= 0 and balance <= WalletStoreSqlite.MAX_YANG)
	runtime_wallets[owner_id].wallet_balance = balance
	runtime_wallets[owner_id].pending_currency_delta = 0
	dirty_wallet.erase(owner_id)

func purchase_shop_offer(owner_id: int, shop: ShopDefinition, offer_id: StringName, requested_position: int = -1) -> Dictionary:
	if db == null or not runtime_wallets.has(owner_id): return {"ok":false, "error":"storage"}
	var result: Dictionary = ShopStoreSqlite.new(db).purchase(owner_id, int(runtime_wallets[owner_id].pending_currency_delta), shop, offer_id, requested_position)
	if result.ok: accept_committed_wallet_balance(owner_id, int(result.balance))
	return result

func upgrade_item(owner_id: int, recipe: UpgradeDefinition, uid: String, revision: int) -> Dictionary:
	if db == null or not runtime_wallets.has(owner_id): return {"ok":false, "error":"storage"}
	if recipe == null or not recipe.validation_errors().is_empty(): return {"ok":false, "error":"invalid_definition"}
	if wallet_balance(owner_id) < recipe.yang_cost: return {"ok":false, "error":"funds"}
	var result: Dictionary = UpgradeStoreSqlite.new(db).upgrade(owner_id,int(runtime_wallets[owner_id].pending_currency_delta),recipe,uid,revision)
	if result.ok: accept_committed_wallet_balance(owner_id,int(result.balance))
	return result

func release_wallet(owner_id: int) -> void:
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
		if not flush_wallet(): push_error("Wallet checkpoint failed; pending income retained for retry.")
	_progression_elapsed += delta
	if _progression_elapsed < PROGRESSION_SAVE_SECONDS: return
	_progression_elapsed = fmod(_progression_elapsed, PROGRESSION_SAVE_SECONDS)
	if not flush_progression(): push_error("Progression checkpoint failed; dirty characters retained for retry.")


func start_database(world_info: Dictionary) -> void:
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
	# Durability + concurrency. WAL lets the live backup byte-copy run alongside
	# writes without tearing (backup_database assumes this) and survives a crash
	# mid-write; NORMAL is the standard safe+fast sync level under WAL. PRAGMAs are
	# connection settings, not schema — no migration / wipe.
	db.query("PRAGMA journal_mode=WAL;")
	db.query("PRAGMA synchronous=NORMAL;")


func close_database() -> void:
	# Plugin doesn’t always expose close explicitly; if it does, call it.
	# Otherwise let refcount drop; but prefer close if available.
	flush_character()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		close_database()


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
## balloon. Runs on the server's own DB connection, so it always gets the lock.
func backup_database(keep_last: int = 10) -> bool:
	if database_path.is_empty():
		return false
	if not FileAccess.file_exists(database_path):
		return false

	if db != null:
		db.query("PRAGMA wal_checkpoint(TRUNCATE);")

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
