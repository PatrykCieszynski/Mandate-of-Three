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
	player.active_guild_id=0;player.led_guild_id=0;player.joined_guild_ids=PackedInt64Array()
	player.inventory={}
	var starting_gold: int=maxi(1,Guild.CREATION_COST*3)
	Inventory.add_item(player.inventory,Economy.gold_id(),starting_gold)
	assert(store.save_player(player))
	var before: Dictionary=player.inventory.duplicate(true)
	var world:=WorldServer.new()
	var database:=WorldDatabase.new()
	world.database=database;database.store=store
	world.connected_players[77]=player
	var previous: Variant=ServerInstance.world_server
	ServerInstance.world_server=world
	var instance:=ServerInstance.new()
	var create:=preload("res://source/server/world/components/data_request_handlers/guild.create.gd").new()
	# BEGIN refusal: no mutation and no attempted COMMIT.
	connection.refuse_begin=true
	var result: Dictionary=create.data_request_handler(77,instance,{"name":"P1 rejected"})
	assert(not result.get("ok",true) and connection.commits==0 and player.inventory==before)
	connection.refuse_begin=false
	# Fail after guild rows were written and live player gold was deducted.
	assert(db.execute("CREATE FUNCTION realm.reject_profile() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture profile failure'; END $$;").ok)
	assert(db.execute("CREATE TRIGGER reject_profile BEFORE UPDATE ON realm.players FOR EACH ROW EXECUTE FUNCTION realm.reject_profile();").ok)
	result=create.data_request_handler(77,instance,{"name":"P1 rejected"})
	assert(not result.get("ok",true) and player.inventory==before and player.led_guild_id==0 and player.joined_guild_ids.is_empty())
	assert(db.query("SELECT guild_id FROM realm.guilds WHERE guild_name='P1 rejected';").rows.is_empty())
	# Even an ignored failed write cannot turn an aborted transaction into success.
	assert(store.begin())
	assert(not store.save_player(player))
	assert(not store.commit())
	assert(not connection.in_transaction())
	# Social state/cache must not move ahead of the failed profile transaction.
	BlockList.clear_player(player.player_id)
	var block:=preload("res://source/server/world/components/data_request_handlers/social.block.add.gd").new()
	result=block.data_request_handler(77,instance,{"id":999999})
	assert(not result.ok and player.blocked_ids.is_empty() and not BlockList.is_blocked(player.player_id,999999))
	assert(db.execute("DROP TRIGGER reject_profile ON realm.players;").ok)
	# Mail grant + claim flag are all-or-nothing; do not emit grants in live RAM.
	var mail:=MailStorePostgres.new(connection)
	database.mail_store=mail
	var mail_id: int=mail.send(player.player_id,"Fixture","Claim","Body",JSON.stringify([{"type":"title","title":"P1 mail reward"}]))
	assert(mail_id>0)
	assert(db.execute("CREATE TRIGGER reject_mail BEFORE INSERT OR UPDATE ON realm.mail_state FOR EACH ROW EXECUTE FUNCTION realm.reject_profile();").ok)
	var claim:=preload("res://source/server/world/components/data_request_handlers/mail.claim.gd").new()
	result=claim.data_request_handler(77,instance,{"mail_id":mail_id})
	assert(not result.ok and not player.titles_unlocked.has("P1 mail reward"))
	assert(not store.get_player(player.player_id).titles_unlocked.has("P1 mail reward"))
	assert(db.query("SELECT mail_id FROM realm.mail_state WHERE mail_id=:id;",{"id":mail_id}).rows.is_empty())
	var read:=preload("res://source/server/world/components/data_request_handlers/mail.read.gd").new()
	assert(not read.data_request_handler(77,instance,{"mail_id":mail_id}).ok)
	assert(db.execute("DROP TRIGGER reject_mail ON realm.mail_state;").ok)
	assert(claim.data_request_handler(77,instance,{"mail_id":mail_id}).ok)
	assert(player.titles_unlocked.has("P1 mail reward"))
	assert(not claim.data_request_handler(77,instance,{"mail_id":mail_id}).ok)
	# A deferred SQL error reaches the actual COMMIT, not just the write call.
	assert(db.execute("CREATE CONSTRAINT TRIGGER reject_commit AFTER UPDATE ON realm.players DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION realm.reject_profile();").ok)
	result=create.data_request_handler(77,instance,{"name":"P1 rejected commit"})
	assert(not result.ok and result.reason=="outcome_unknown" and not result.retryable)
	assert(player.inventory==before and player.led_guild_id==0)
	assert(db.query("SELECT guild_id FROM realm.guilds WHERE guild_name='P1 rejected commit';").rows.is_empty())
	assert(db.execute("DROP TRIGGER reject_commit ON realm.players;").ok)
	assert(db.execute("DROP FUNCTION realm.reject_profile();").ok)
	# Successful COMMIT, lost acknowledgement: return unknown, close and do not
	# repeat the mutation. A fresh owner must reload the durable player state.
	connection=Connection.new();connection.lose_commit=true
	store=WorldStorePostgres.new(connection);database.store=store
	result=create.data_request_handler(77,instance,{"name":"P1 lost commit"})
	assert(not result.ok and result.reason=="outcome_unknown" and not result.retryable)
	assert(player.inventory==before and player.led_guild_id==0)
	assert(db.query("SELECT guild_id FROM realm.guilds WHERE guild_name='P1 lost commit';").rows.size()==1)
	var committed: PlayerResource=WorldStorePostgres.new(db).get_player(player.player_id)
	assert(committed.led_guild_id>0 and Inventory.count(committed.inventory,Economy.gold_id())==starting_gold-Guild.CREATION_COST)
	assert(not create.data_request_handler(77,instance,{"name":"P1 lost commit"}).ok and connection.commits==1)
	instance.free();world.free();database.free()
	ServerInstance.world_server=previous
	BlockList.clear_player(player.player_id)
	print("POSTGRES_PROFILE_FAILURE_OK: BEGIN/write/deferred-COMMIT failures, RAM and block-cache rollback, atomic mail, lost committed result without replay")
