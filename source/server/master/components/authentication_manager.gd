class_name AuthenticationManager
extends Node


var account_collection: AccountResourceCollection
## Production path (writable). In an exported build res:// is read-only, so
## ResourceSaver.save() against res:// silently fails and accounts can't
## persist. Mirrors the world-db split: editor reads/writes res://, exports
## live under user://. NO seed fallback — production starts blank by design,
## dev/debug accounts never leak into the live environment.
var account_collection_path: String:
	get:
		if not _configured_collection_path.is_empty(): return _configured_collection_path
		if OS.has_feature("editor"):
			return "res://source/server/master/account_collection.tres"
		return "user://master/account_collection.tres"
var _configured_collection_path: String=""
var _frozen_checkpoint:=false
var postgres_store: RefCounted
var storage_ready:=true
var active_accounts: Dictionary[StringName, AccountResource]


func _ready() -> void:
	var config:=ConfigFile.new()
	if config.load(CmdlineUtils.get_parsed_args().get("config","res://data/config/master_config.cfg"))==OK:
		_configured_collection_path=str(config.get_value("authentication","account_collection_path",""))
	if not _configured_collection_path.is_empty(): DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_configured_collection_path.get_base_dir()))
	tree_exiting.connect(save_account_collection)
	load_account_collection()


# Cryptographically-secure random token (256 bits, hex-encoded → 64 chars). Used
# for world-handoff auth tokens and guest passwords; both need to be unguessable.
func generate_random_token() -> String:
	return Crypto.new().generate_random_bytes(32).hex_encode()


func create_account(username: String, password: String, is_guest: bool) -> AccountResource:
	if not storage_ready or _frozen_checkpoint: return null
	# Account names are case-insensitive (like Discord) so "John" and "john"
	# can't both exist. Normalize to lowercase before any lookup / storage.
	if not is_guest:
		username = username.strip_edges().to_lower()
	if not is_guest and username_exists(username):
		return null
	if postgres_store!=null:
		if is_guest: password=generate_random_token()
		var created: AccountResource=postgres_store.create(username,password,is_guest)
		if created!=null: account_collection.collection[created.username]=created
		elif not postgres_store.db.is_open(): storage_ready=false
		return created
	var account_id: int = account_collection.get_new_account_id()
	if is_guest:
		username = "guest%d" % account_id
		password = generate_random_token()
	# Store only a salted, key-stretched hash — never the plaintext password.
	var new_account: AccountResource = AccountResource.new()
	new_account.init(account_id, username, PasswordHasher.hash_password(password))
	account_collection.collection[username] = new_account
	# Save on disk should only occur at specific times.
	# Temporary work around for debug purpose.
	save_account_collection()
	return new_account


func load_account_collection() -> void:
	var config_path: String=CmdlineUtils.get_parsed_args().get("config","res://data/config/master_config.cfg")
	var config:=ConfigFile.new()
	if config.load(config_path)==OK and config.get_value("economy","realm_state",false):
		account_collection=AccountResourceCollection.new()
		storage_ready=false
		var settings: Dictionary=preload("res://source/server/world/database/postgres/economy_bootstrap_settings.gd").load_config(config_path)
		if not settings.ok or settings.backend!="postgresql": return
		var connection: Object=preload("res://source/server/world/database/postgres/realm_schema_postgres.gd").connect_store(settings)
		if connection==null: return
		postgres_store=preload("res://source/server/master/account_models/account_store_postgres.gd").new(connection)
		var loaded: AccountResourceCollection=postgres_store.load_accounts()
		if loaded==null: connection.close();return
		account_collection=loaded
		storage_ready=true
		return
	if ResourceLoader.exists(account_collection_path):
		account_collection = ResourceLoader.load(account_collection_path)
	else:
		account_collection = AccountResourceCollection.new()


func save_account_collection() -> bool:
	if _frozen_checkpoint: return true
	# Ensure user://master/ exists before the first save in an export build.
	if not OS.has_feature("editor"):
		DirAccess.make_dir_recursive_absolute("user://master")
	return checkpoint_accounts()

func checkpoint_accounts(freeze: bool = false) -> bool:
	if _frozen_checkpoint: return true
	if not storage_ready: return false
	if postgres_store!=null:
		var saved: bool=postgres_store.checkpoint(account_collection)
		if not saved: storage_ready=false # Do not authenticate an uncommitted RAM password.
		if saved and freeze:
			_frozen_checkpoint=true
			postgres_store.db.close()
		return saved
	var saved: bool=account_collection!=null and ResourceSaver.save(account_collection,account_collection_path)==OK
	if saved and freeze: _frozen_checkpoint=true
	return saved


func username_exists(username: String) -> bool:
	return account_collection.collection.has(username.strip_edges().to_lower())


func validate_credentials(username: String, password: String) -> AccountResource:
	if not storage_ready: return null
	# Case-insensitive lookup to match create_account's lowercase normalization.
	username = username.strip_edges().to_lower()
	var account: AccountResource = null
	if account_collection.collection.has(username):
		account = account_collection.collection[username]
		if PasswordHasher.verify(password, account.password):
			return account
	return null

func _exit_tree() -> void:
	if postgres_store!=null:
		if not _frozen_checkpoint: checkpoint_accounts()
		postgres_store.db.close()
