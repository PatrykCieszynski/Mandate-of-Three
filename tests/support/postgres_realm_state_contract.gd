extends RefCounted
## Durable state/reopen and rollback contracts, not menu structure or UI geometry.
static func run(db: Object) -> void:
	assert(db.execute("SET search_path TO realm,pg_catalog;").ok)
	var accounts:=preload("res://source/server/master/account_models/account_store_postgres.gd").new(db)
	assert(accounts.load_accounts()!=null)
	var first: AccountResource=accounts.create("realmtest","Disposable-only-Password-2",false)
	assert(first!=null and first.id>1 and PasswordHasher.verify("Disposable-only-Password-2",first.password))
	assert(accounts.create("realmtest","Other-test-password",false)==null)
	var guest: AccountResource=accounts.create("","Disposable-guest-only",true)
	assert(guest!=null and guest.id>first.id and guest.username=="guest%d" % guest.id)
	var collection: AccountResourceCollection=accounts.load_accounts()
	assert(collection.collection[first.username].password==first.password)
	first.last_character_id=7
	first.last_world_name="Fixture"
	collection.collection[first.username]=first
	assert(accounts.checkpoint(collection))
	assert(accounts.load_accounts().collection[first.username].last_character_id==7)
	var store:=preload("res://source/server/world/database/postgres/world_store_postgres.gd").new(db)
	assert(store.bind_account_identity(first.username,first.id,true))
	assert(not store.bind_account_identity(first.username,guest.id,true))
	var id: int=store.create_player_character(first.username,{"name":"Profile fixture","skin":1})
	assert(id>0 and store.resolve_account_id(id)==first.id)
	var player: PlayerResource=store.get_player(id)
	player.experience=43
	player.profile_status="Untouched by XP checkpoint"
	player.friends=PackedInt64Array([7,8])
	assert(store.save_player(player))
	player.experience=51
	player.profile_status="Do not persist this during XP save"
	var batch: Array[PlayerResource]=[player]
	assert(store.save_progression(batch))
	var restored: PlayerResource=store.get_player(id)
	assert(restored.experience==51 and restored.profile_status=="Untouched by XP checkpoint" and restored.friends==PackedInt64Array([7,8]))
	player.experience=77
	var missing:=PlayerResource.new();missing.init(999999,first.username,"Missing",1)
	batch.append(missing)
	assert(not store.save_progression(batch))
	assert(store.get_player(id).experience==51,"whole checkpoint batch rolls back")
	player.account_name=guest.username
	assert(not store.save_player(player),"an upsert cannot transfer profile ownership")
	assert(store.get_player(id).account_name==first.username)
	store.begin()
	var guild_id: int=store.create_guild("Realm fixture guild",id)
	assert(guild_id>0)
	store.commit()
	var guild: Guild=store.get_guild(guild_id)
	guild.members[id]=0
	guild.description="Persistent guild"
	store.begin();store.save_guild(guild);store.commit()
	assert(store.get_guild(guild_id).members.has(id))
	store.add_guild_log(guild_id,"fixture")
	assert(store.get_guild_log(guild_id).size()==1)
	var chat:=preload("res://source/server/world/database/postgres/chat_store_postgres.gd").new(db)
	chat.ensure_conversation("fixture","dm")
	assert(chat.insert_message("fixture",1,id,"Fixture","One").msg_id==1)
	assert(chat.insert_message("fixture",2,id,"Fixture","Two").msg_id==2)
	assert(chat.fetch_last("fixture").size()==2)
	var mail:=preload("res://source/server/world/database/postgres/mail_store_postgres.gd").new(db)
	var mail_id: int=mail.send(id,"Fixture","Subject","Body","[]")
	assert(mail_id>0 and mail.unread_count(id)==1)
	mail.mark_read(id,mail_id)
	assert(mail.unread_count(id)==0)
	mail.soft_delete(id,mail_id)
	assert(mail.inbox_for(id).is_empty())
	# A failed credential checkpoint must not authenticate an uncommitted RAM hash.
	var auth:=AuthenticationManager.new()
	auth.account_collection=accounts.load_accounts()
	auth.postgres_store=accounts
	auth.account_collection.collection[first.username].password=PasswordHasher.hash_password("Uncommitted-test-password")
	db.close()
	assert(not auth.checkpoint_accounts() and not auth.storage_ready)
	assert(auth.validate_credentials(first.username,"Uncommitted-test-password")==null)
	auth.free()
	print("POSTGRES_REALM_STATE_CONTRACT_OK: account IDs/hashes/reopen, credential failure closes authentication, profile ownership, three-field batch rollback, guild/chat/mail")
