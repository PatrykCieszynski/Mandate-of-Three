extends Node
func _ready() -> void:
	var contract=preload("res://tests/support/character_stats_contract.gd")
	contract.model()
	var db:=SqliteSoci.new();db.path="res://.godot/verification/stats-v1.db"
	# Fixed disposable fixture, no real profile data.
	if FileAccess.file_exists(db.path): DirAccess.remove_absolute(db.path)
	assert(db.open_db());WorldSchema.ensure_schema(db)
	var store:=WorldStoreSqlite.new(db)
	var owner: int=preload("res://tests/economy_fixture.gd").create_character(store,"stats_v1",{"name":"Stats","skin":1})
	assert(owner>0)
	contract.persistence(store,store.get_player(owner))
	var player: PlayerResource=store.get_player(owner)
	var before: int=player.available_attributes_points
	assert(db.query("CREATE TEMP TRIGGER reject_stats BEFORE UPDATE ON players BEGIN SELECT RAISE(ABORT,'stats rollback'); END;"))
	assert(not store.spend_attribute(player,"stats-rollback",&"STR").ok)
	assert(player.available_attributes_points==before)
	assert(db.query("SELECT * FROM stats_commands WHERE command_id='stats-rollback';") and db.query_result.is_empty())
	assert(db.query("DROP TRIGGER reject_stats;"))
	assert(store.spend_attribute(player,"stats-rollback",&"STR").ok)
	# A migrated runtime profile is dirty even if no new XP arrives this session.
	player=store.get_player(owner);player.attributes={&"defense":2};player.stats_version=0
	assert(store.save_player(player))
	var persistence:=WorldDatabase.new();persistence.db=db;persistence.store=store
	var migrated: PlayerResource=persistence.get_player_resource(owner)
	assert(persistence.dirty_progression.get(owner)==migrated)
	assert(persistence.get_player_resource(owner)==migrated)
	assert(persistence.flush_progression(owner) and not store.get_player(owner).stats_migrated)
	persistence.free()
	db.close_db()
	print("STATS_V1_OK milestones, multi-level, no retroactive rewards, party, composition, persistent allocation, replay, race, rollback, migration")
	get_tree().quit()
