extends Node
## New risk: verified identity handoff and additive migration are not covered by item suites.
class SessionServer extends WorldServer:
	var master_disconnects: Array[String] = []
	func _notify_master_disconnected(account_name: String, _session_token: String = "") -> void:
		master_disconnects.append(account_name)

var db := SQLite.new()

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot/verification"))
	db.path = "res://.godot/verification/account-identity.db"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
	assert(db.open_db())
	# Populated v16 fixture. Fault after ALTER must roll back schema as well as data.
	assert(db.query("CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); INSERT INTO meta VALUES('schema_version','16'); CREATE TABLE accounts(account_name TEXT PRIMARY KEY NOT NULL); INSERT INTO accounts VALUES('legacy'); CREATE TRIGGER fail_identity_version BEFORE INSERT ON meta WHEN NEW.value='17' BEGIN SELECT RAISE(ABORT,'identity checkpoint failure'); END;"))
	assert(not WorldSchema.migrate_account_identity(db))
	assert(db.query("PRAGMA table_info(accounts);"))
	assert(db.query_result.size()==1,"failed migration rolls back added column")
	assert(db.query("SELECT value FROM meta WHERE key='schema_version';") and db.query_result[0].value=="16")
	assert(db.query("DROP TRIGGER fail_identity_version;"))
	WorldSchema.ensure_schema(db)
	WorldSchema.ensure_schema(db)
	assert(db.query("SELECT COUNT(*) AS n FROM accounts;") and db.query_result[0].n==1,"migration/retry never creates accounts")
	assert(db.close_db() and db.open_db())
	WorldSchema.ensure_schema(db)
	assert(db.query("SELECT account_name,master_account_id FROM accounts;") and db.query_result[0].account_name=="legacy" and db.query_result[0].master_account_id==null)
	assert(db.close_db())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
	assert(db.open_db())
	WorldSchema.ensure_schema(db)
	var store := WorldStoreSqlite.new(db)
	assert(WalletStoreSqlite.migrate_accounts(db,{}).ok)
	assert(store.bind_account_identity("alpha",21,true) and store.bind_account_identity("beta",22,true))
	var characters: Array[int] = []
	for account: String in ["alpha","beta"]:
		for index: int in 2:
			characters.append(store.create_player_character(account,{"name":account+str(index),"skin":1}))
	var database := WorldDatabase.new()
	database.db = db
	database.store = store
	assert(database.prepare_account_wallets({"alpha":21,"beta":22}).ok)
	var server := SessionServer.new()
	server.database = database
	assert(server.accept_master_handoff("a0","alpha",characters[0],21))
	assert(server.accept_master_handoff("a1","alpha",characters[1],21))
	assert(server.accept_master_handoff("b0","beta",characters[2],22))
	assert(server.accept_master_handoff("b1","beta",characters[3],22))
	assert(server.resolve_account_id(characters[0])==21 and server.resolve_account_id(characters[1])==21)
	assert(server.resolve_account_id(characters[2])==22 and server.resolve_account_id(characters[3])==22)
	assert(not db.query("INSERT INTO accounts(account_name,master_account_id) VALUES('duplicate_sql',21);"),"SQL unique constraint prevents duplicate Master identity")
	assert(not db.query("INSERT INTO accounts(account_name,master_account_id) VALUES('invalid_sql',0);"),"SQL rejects invalid identity independently of the helper")
	assert(not server.accept_master_handoff("spoof","beta",characters[0],22))
	assert(not server.accept_master_handoff("mismatch","alpha",characters[0],22))
	assert(not server.accept_master_handoff("duplicate","beta",characters[2],21))
	assert(not server.token_list.has("spoof") and not server.token_list.has("mismatch") and not server.token_list.has("duplicate"))
	assert(not store.bind_account_identity("orphan",23) and not store.bind_account_identity("alpha",0))
	assert(db.query("CREATE TRIGGER fail_binding BEFORE UPDATE ON accounts BEGIN SELECT RAISE(ABORT,'identity bind failure'); END;"))
	assert(not server.accept_master_handoff("failed_commit","alpha",characters[0],21) and not server.token_list.has("failed_commit"),"SQL failure cannot install an authentication token")
	assert(store.resolve_account_id(characters[0])==21 and db.query("DROP TRIGGER fail_binding;"))
	server.connected_players[123] = store.get_player(characters[0])
	assert(server.resolve_peer_account_id(123)==21 and server.resolve_peer_account_id(999)==0)
	assert(db.close_db() and db.open_db())
	WorldSchema.ensure_schema(db)
	assert(store.resolve_account_id(characters[0])==21 and store.resolve_account_id(characters[3])==22)
	assert(db.query("INSERT INTO accounts(account_name) VALUES('unbound');"))
	assert(store.unbound_accounts().size()==1 and store.resolve_account_id(-1)==0)
	var audit := store.audit_account_identities({"alpha":21,"beta":999,"unbound":23})
	assert(audit.ok and audit.unbound==["unbound"] and audit.mismatched==["beta"] and audit.orphaned.is_empty())
	assert(store.audit_account_identities({"alpha":21}).orphaned.size()==2,"deleted Master accounts are reported without remapping")
	# Current-owner disconnect must still persist/clean its own character. Another
	# current character of that account must not be reported offline at Master.
	server.connected_players.clear()
	var first := store.get_player(characters[0])
	var second := store.get_player(characters[1])
	first.current_peer_id = 600
	second.current_peer_id = 601
	first.level = 3
	assert(database.load_wallet(first.player_id))
	server.connected_players[600] = first
	server.connected_players[601] = second
	server.player_id_to_peer_id[first.player_id] = 600
	server.player_id_to_peer_id[second.player_id] = 601
	server.runtime_equipment[first.player_id] = {"stats": {"attack": 37}}
	server._on_peer_disconnected(600)
	assert(first.current_peer_id == 0 and not server.player_id_to_peer_id.has(first.player_id))
	assert(not server.connected_players.has(600) and server.runtime_attack(first.player_id) == -1)
	assert(store.get_player(first.player_id).level == 3, "current owner's disconnect still saves")
	assert(server.master_disconnects.is_empty() and server.connected_players[601] == second)
	server._on_peer_disconnected(600) # Unknown/duplicate callbacks never notify Master.
	assert(database.wallet_balance(second.player_id) >= 0, "other current session keeps the shared wallet")
	var stale := second.duplicate() as PlayerResource
	stale.current_peer_id = 599
	server.connected_players[599] = stale
	server._on_peer_disconnected(601)
	assert(database.wallet_balance(second.player_id) == -1, "stale peer must not retain the last session's clean wallet")
	server._on_peer_disconnected(599)
	assert(second.current_peer_id == 0 and not server.player_id_to_peer_id.has(second.player_id))
	assert(server.connected_players.is_empty() and server.master_disconnects == ["alpha"])
	var gateway := preload("res://source/server/gateway/http_server.gd").new()
	var token := gateway.create_session({"name":"alpha","id":21})
	assert(gateway.verified_session({"t-id":token,"a-u":"alpha","a-id":22}).id==21)
	assert(gateway.verified_session({"t-id":token,"a-u":"beta"}).is_empty())
	assert(gateway.verified_session({"t-id":"fake","a-u":"alpha"}).is_empty())
	gateway.free()
	server.free()
	database.db = null
	database.free()
	assert(db.close_db())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(db.path))
	print("ACCOUNT_IDENTITY_OK migration rollback/restart, two accounts/two alts, handoff ownership, session spoof rejection")
	get_tree().quit()
