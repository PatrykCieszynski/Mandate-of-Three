extends RefCounted
static func model() -> void:
	var p:=PlayerResource.new()
	assert(p.add_experience(17).points_gained==0)
	assert(p.add_experience(1).points_gained==1 and p.available_attributes_points==1)
	assert(p.add_experience(17).points_gained==1)
	assert(p.add_experience(18).points_gained==1)
	assert(p.add_experience(17).points_gained==0 and p.level==2 and p.available_skill_points==1)
	assert(p.available_attributes_points==3 and p.exp_thresholds_claimed==0)
	var bulk:=PlayerResource.new();var small:=PlayerResource.new()
	bulk.add_experience(70+140+210+50)
	for i: int in 470: small.add_experience(1)
	assert(bulk.level==4 and bulk.experience==50 and bulk.available_attributes_points==9 and bulk.available_skill_points==3)
	assert(bulk.progression_state()==small.progression_state() and bulk.available_attributes_points==small.available_attributes_points)
	var old:=PlayerResource.new();old.level=3;old.experience=110;old.available_attributes_points=5
	old.attributes={&"strenght":4,&"agility":3,&"vitality":2,&"defense":1,&"intelligence":5,&"spirit":6}
	old.load_progression_state({})
	assert(old.available_attributes_points==26 and old.attributes.is_empty() and old.available_skill_points==0 and old.exp_thresholds_claimed==2)
	assert(old.add_experience(47).points_gained==0)
	assert(old.add_experience(1).points_gained==1)
	var split=preload("res://source/common/gameplay/party/party_exp.gd")
	for mode: String in ["equal","by_level","carry"]:
		var shares: Dictionary=split.split(700,[{"id":1,"level":1},{"id":2,"level":11}],mode)
		assert(int(shares[1])+int(shares[2])==700)
		for id: int in shares:
			var a:=PlayerResource.new();var b:=PlayerResource.new()
			a.level=1 if id==1 else 11;b.level=a.level
			a.add_experience(shares[id])
			for i: int in shares[id]: b.add_experience(1)
			assert(a.progression_state()==b.progression_state() and a.available_attributes_points==b.available_attributes_points and a.experience==b.experience)
	var world:=WorldServer.new();var actor:=PlayerResource.new();actor.init(7,"stats")
	world.connected_players[70]=actor;world.player_id_to_peer_id[7]=70
	world.runtime_equipment[7]={"stats":{"attack":23.0,"attack_speed":110.0,"health_max":4.0}}
	actor.active_buffs=[{"stat":Stat.AD,"amount":3.0,"expires_ms":Time.get_ticks_msec()+10000}]
	actor.attributes={&"STR":4,&"DEX":4,&"VIT":2,&"INT":2}
	var stats:=world.runtime_combat_stats(7)
	assert(stats.attack==31.0 and is_equal_approx(stats.attack_speed,110.4) and stats.health_max==124.0)
	assert(stats.armor==0.5 and stats.mana_max==60.0 and is_equal_approx(stats.mana_regen,0.6))
	assert(world.runtime_equipment[7].stats.attack==23.0,"composition never rewrites equipment")
	actor.level=9
	assert(world.runtime_combat_stats(7).attack==31.0,"level has no hidden damage multiplier")
	assert(world.runtime_combat_stats(7).health_max==164.0,"existing HP per-level constant remains")
	assert(AttributeMap.weighted(actor.attributes,{&"STR":2.0,&"INT":3.0})==14.0)
	world.free()

static func persistence(store: RefCounted, player: PlayerResource) -> void:
	player.level=1;player.experience=0;player.attributes.clear();player.available_attributes_points=0
	player.available_skill_points=0;player.exp_thresholds_claimed=0;player.stats_version=1;player.stats_revision=0
	assert(store.save_player(player))
	player.add_experience(105)
	assert(store.get_player(player.player_id).experience==0)
	var spent: Dictionary=store.spend_attribute(player,"stats-first",&"STR")
	assert(spent.ok and spent.points==3 and player.attributes.is_empty(),"store commits without speculative RAM mutation: "+JSON.stringify(spent)+" tx="+str(store.db.in_transaction() if store.db.has_method("in_transaction") else false))
	var loaded: PlayerResource=store.get_player(player.player_id)
	assert(loaded.level==2 and loaded.experience==35 and loaded.attributes[&"STR"]==1 and loaded.available_skill_points==1 and loaded.exp_thresholds_claimed==1)
	assert(store.spend_attribute(loaded,"stats-first",&"STR").replay)
	assert(store.spend_attribute(loaded,"stats-first",&"DEX").error=="command_conflict")
	assert(store.get_player(player.player_id).available_attributes_points==3)
	# Two loaded contenders for the final point: only one can commit at that revision.
	loaded.available_attributes_points=1;assert(checkpoint(store,loaded))
	var competing: PlayerResource=store.get_player(player.player_id)
	assert(store.spend_attribute(loaded,"stats-last",&"VIT").ok)
	assert(not store.spend_attribute(competing,"stats-race",&"INT").ok)
	loaded=store.get_player(player.player_id)
	assert(loaded.available_attributes_points==0 and loaded.attributes[&"VIT"]==1)
	assert(store.spend_attribute(loaded,"stats-last",&"VIT").replay,"receipt lookup precedes exhausted-point validation")
	assert(not store.spend_attribute(loaded,"stats-empty",&"STR").ok)
	loaded.add_experience(70)
	assert(checkpoint(store,loaded))
	var reloaded: PlayerResource=store.get_player(player.player_id)
	var points:=reloaded.available_attributes_points
	assert(reloaded.add_experience(1).points_gained==0 and reloaded.available_attributes_points==points,"checkpoint/relog cannot re-award milestones")
	# Old profile JSON roundtrip, followed by durable one-time refund.
	loaded.attributes={&"strenght":4,&"spirit":3};loaded.available_attributes_points=5
	loaded.stats_version=0;assert(store.save_player(loaded))
	loaded=store.get_player(player.player_id)
	assert(loaded.attributes.is_empty() and loaded.available_attributes_points==12 and loaded.stats_migrated)
	assert(checkpoint(store,loaded))
	loaded=store.get_player(player.player_id)
	assert(loaded.available_attributes_points==12 and not loaded.stats_migrated)
	# No gameplay cap and no float-based rounding of persisted point counters.
	loaded.attributes={&"STR":9007199254740993};loaded.available_skill_points=9007199254740993
	assert(store.save_player(loaded))
	var large: PlayerResource=store.get_player(player.player_id)
	assert(large.attributes[&"STR"]==9007199254740993 and large.available_skill_points==9007199254740993)
	large.attributes.clear();large.available_skill_points=loaded.level-1
	assert(store.save_player(large))

static func checkpoint(store: RefCounted, player: PlayerResource) -> bool:
	var players: Array[PlayerResource]=[player]
	return store.save_progression(players)

static func postgres_failures(db: Object, player: PlayerResource) -> void:
	var proxy_type=preload("res://tests/support/postgres_profile_failure_contract.gd")
	# Independent sessions contend on the profile row; timeout cannot leave a receipt.
	var lock=proxy_type.Connection.new()
	assert(lock.begin() and lock.query("SELECT player_id FROM realm.players WHERE player_id=:id FOR UPDATE;",{"id":player.player_id}).ok)
	var contending=proxy_type.Connection.new()
	assert(contending.execute("SET lock_timeout='100ms';").ok)
	var blocked:=WorldStorePostgres.new(contending)
	assert(not blocked.spend_attribute(player,"stats-row-lock",&"DEX").ok)
	assert(db.query("SELECT command_id FROM realm.stats_commands WHERE command_id='stats-row-lock';").rows.is_empty())
	assert(lock.rollback());lock.close();contending.close()
	var connection=proxy_type.Connection.new()
	var writer:=WorldStorePostgres.new(connection)
	var before:=player.available_attributes_points
	var attributes:=player.attributes.duplicate()
	connection.lose_commit=true
	var result: Dictionary=writer.spend_attribute(player,"stats-lost-commit",&"STR")
	assert(not result.ok and result.error=="outcome_unknown")
	assert(player.available_attributes_points==before and player.attributes==attributes,"unknown outcome does not publish speculative state")
	assert(not writer.spend_attribute(player,"stats-lost-commit",&"STR").ok and connection.commits==1,"closed owner cannot blindly replay")
	var fresh:=WorldStorePostgres.new(db)
	var restored: PlayerResource=fresh.get_player(player.player_id)
	assert(restored.available_attributes_points==before-1)
	assert(fresh.spend_attribute(restored,"stats-lost-commit",&"STR").replay)
	# A deferred error is reported only at COMMIT; the receipt and allocation roll back.
	assert(db.execute("CREATE FUNCTION realm.reject_stats_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'stats deferred failure'; END $$;").ok)
	assert(db.execute("CREATE CONSTRAINT TRIGGER reject_stats AFTER UPDATE ON realm.players DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION realm.reject_stats_commit();").ok)
	connection=proxy_type.Connection.new();writer=WorldStorePostgres.new(connection)
	result=writer.spend_attribute(restored,"stats-deferred-commit",&"VIT")
	assert(not result.ok and result.error=="outcome_unknown")
	assert(db.query("SELECT command_id FROM realm.stats_commands WHERE command_id='stats-deferred-commit';").rows.is_empty())
	assert(fresh.get_player(player.player_id).available_attributes_points==restored.available_attributes_points)
	assert(db.execute("DROP TRIGGER reject_stats ON realm.players;").ok)
	assert(db.execute("DROP FUNCTION realm.reject_stats_commit();").ok)
	print("POSTGRES_STATS_OK allocation, checkpoint, migration, race, replay, lost/deferred COMMIT recovery")
