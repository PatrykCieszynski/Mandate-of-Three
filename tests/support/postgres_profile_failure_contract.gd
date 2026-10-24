extends RefCounted
## Real SQL failures through production handlers. The proxy only loses delivery
## of an already successful COMMIT; writes and rollback run on PostgreSQL.
class Connection extends RefCounted:
	var inner: Object
	var refuse_begin:=false
	var lose_commit:=false
	var commits:=0
	func _init() -> void:
		inner=ClassDB.instantiate("GodotSociDatabase")
		assert(inner.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
		assert(inner.execute("SET search_path TO realm,pg_catalog;").ok)
	func begin() -> bool: return false if refuse_begin else inner.begin()
	func commit() -> bool:
		commits+=1
		var ok: bool=inner.commit()
		return ok and not lose_commit
	func rollback() -> bool: return inner.rollback()
	func close() -> void: inner.close()
	func in_transaction() -> bool: return inner.in_transaction()
	func query(sql: String, values: Dictionary={}, limit: int=100000) -> Dictionary: return inner.query(sql,values,limit)
	func execute(sql: String, values: Dictionary={}) -> Dictionary: return inner.execute(sql,values)

static func run(db: Object, player: PlayerResource) -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection:=Connection.new()
	var store:=WorldStorePostgres.new(connection)
	player.blocked_ids=PackedInt64Array()
	player.friends=PackedInt64Array([999999])
	assert(store.save_player(player))
	var world:=WorldServer.new()
	var database:=WorldDatabase.new();database.store=store;world.database=database
	world.connected_players[77]=player
	world.player_id_to_peer_id[player.player_id]=77
	var instance:=ServerInstance.new();var previous: Variant=ServerInstance.world_server
	ServerInstance.world_server=world
	var block:=preload("res://source/server/world/components/data_request_handlers/social.block.add.gd").new()
	BlockList.clear_player(player.player_id)
	var profile: Dictionary=preload("res://source/server/world/components/data_request_handlers/profile.get.gd").new().data_request_handler(77,instance,{})
	assert(not profile.has("guild_name") and not profile.has("can_guild_invite") and not profile.stats.has("money"),"retired guild/JSON currency cannot become live profile presentation")
	connection.refuse_begin=true
	var result: Dictionary=block.data_request_handler(77,instance,{"id":999999})
	assert(not result.ok and connection.commits==0 and player.blocked_ids.is_empty())
	connection.refuse_begin=false
	assert(db.execute("CREATE FUNCTION realm.reject_profile() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture profile failure'; END $$;").ok)
	assert(db.execute("CREATE TRIGGER reject_profile BEFORE UPDATE ON realm.players FOR EACH ROW EXECUTE FUNCTION realm.reject_profile();").ok)
	result=block.data_request_handler(77,instance,{"id":999999})
	assert(not result.ok and player.blocked_ids.is_empty() and player.friends.has(999999))
	assert(not BlockList.is_blocked(player.player_id,999999))
	assert(store.get_player(player.player_id).blocked_ids.is_empty())
	assert(store.begin())
	assert(not store.save_player(player))
	assert(not store.commit() and not connection.in_transaction())
	assert(db.execute("DROP TRIGGER reject_profile ON realm.players;").ok)
	assert(db.execute("CREATE CONSTRAINT TRIGGER reject_commit AFTER UPDATE ON realm.players DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION realm.reject_profile();").ok)
	result=block.data_request_handler(77,instance,{"id":999999})
	assert(not result.ok and result.reason=="outcome_unknown" and not result.retryable)
	assert(player.blocked_ids.is_empty() and player.friends.has(999999))
	assert(not BlockList.is_blocked(player.player_id,999999))
	assert(db.query("SELECT blocked_ids_json FROM realm.players WHERE player_id=:id;",{"id":player.player_id}).rows[0].blocked_ids_json=="[]")
	assert(db.execute("DROP TRIGGER reject_commit ON realm.players;").ok)
	assert(db.execute("DROP FUNCTION realm.reject_profile();").ok)
	connection=Connection.new();connection.lose_commit=true
	store=WorldStorePostgres.new(connection);database.store=store
	result=block.data_request_handler(77,instance,{"id":999999})
	assert(not result.ok and result.reason=="outcome_unknown" and not result.retryable)
	assert(player.blocked_ids.is_empty() and player.friends.has(999999))
	assert(not BlockList.is_blocked(player.player_id,999999))
	var committed: PlayerResource=WorldStorePostgres.new(db).get_player(player.player_id)
	assert(committed.blocked_ids.has(999999) and not committed.friends.has(999999))
	assert(not block.data_request_handler(77,instance,{"id":999999}).ok and connection.commits==1)
	instance.free();world.free();database.free()
	ServerInstance.world_server=previous
	BlockList.clear_player(player.player_id)
	print("POSTGRES_PROFILE_FAILURE_OK: BEGIN/write/deferred-COMMIT failures, RAM and block-cache rollback, lost committed result without replay")
