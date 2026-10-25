extends Node
const Schema=preload("res://source/server/world/database/postgres/auction_search_schema_postgres.gd")
const Items=preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet=preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Craft=preload("res://source/server/world/database/postgres/crafting_store_postgres.gd")
const Rules=preload("res://source/common/gameplay/items/crafting/crafting_rules.gd")
var db: Object
const OWNER=165000
func state() -> Array: return Items.new(db).inventory(OWNER).items
func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	db=ClassDB.instantiate("GodotSociDatabase")
	assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and Schema.ensure_schema(db))
	assert(Wallet.new(db).initialize_account(16500).ok and Items.new(db).bind_character(OWNER,16500))
	var target:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,[])
	target.upgrade_level=4;target.sockets=[{"definition_id":"preserved"}]
	var currencies: Array=[]
	for definition: ItemDefinition in [ItemDefinitions.CHANGE_SPARK,ItemDefinitions.RENEWAL_DUST,ItemDefinitions.COMPLETION_SHARD]:
		var item:=ItemInstance.create(definition,OWNER,[]);item.amount=20;currencies.append(item)
	assert(db.begin())
	for item: ItemInstance in [target]+currencies: assert(Items.new(db).receive_item_in_transaction(item).ok)
	assert(db.commit())
	var before:=state()
	var store:=Craft.new(db)
	# Deferred receipt failure is an uncertain COMMIT, never retried or treated
	# as a free failed gameplay roll. Both currency and target stay unchanged.
	assert(db.execute("CREATE FUNCTION economy.craft_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'craft rollback'; END; $$;").ok)
	assert(db.execute("CREATE CONSTRAINT TRIGGER craft_fault AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
	var failed:=store.execute(OWNER,0,target.uid,0,currencies[0].uid,0,"craft-unknown")
	assert(failed.get("outcome_unknown",false) and not store.committed)
	assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
	assert(state()==before and db.query("SELECT command_id FROM economy.market_commands WHERE command_id='craft-unknown';").rows.is_empty())
	assert(db.execute("DROP TRIGGER craft_fault ON economy.market_commands;").ok)
	store=Craft.new(db)
	var outcome:=store.execute(OWNER,0,target.uid,0,currencies[0].uid,0,"craft-paid")
	assert(outcome.ok and store.committed and outcome.rarity=="magic")
	var frozen:=state()
	assert(store.execute(OWNER,0,target.uid,0,currencies[0].uid,0,"craft-paid")==outcome and store.receipt_replay and state()==frozen)
	assert(store.execute(OWNER,0,target.uid,0,currencies[1].uid,0,"craft-paid").error=="command_conflict")
	assert(store.execute(OWNER,0,target.uid,0,currencies[1].uid,0,"craft-stale").error=="stale" and state()==frozen)
	assert(store.execute(OWNER,0,target.uid,1,currencies[0].uid,1,"craft-wrong-rarity").error=="rarity" and state()==frozen)
	var saved: Dictionary=frozen.filter(func(i: Dictionary)->bool:return i.uid==target.uid)[0]
	assert(saved.sockets==target.sockets and saved.upgrade_level==4 and saved.uid==target.uid)
	# Statement failure after currency decrement must roll everything back.
	assert(db.execute("CREATE TRIGGER craft_fault BEFORE UPDATE OF affixes_json ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
	assert(store.execute(OWNER,0,target.uid,1,currencies[1].uid,0,"craft-write-fault").error=="storage" and state()==frozen)
	assert(db.execute("DROP TRIGGER craft_fault ON economy.item_instances;").ok)
	assert(store.execute(OWNER,0,target.uid,1,currencies[1].uid,0,"craft-renew").ok)
	var renewed: Dictionary=state().filter(func(i: Dictionary)->bool:return i.uid==target.uid)[0]
	assert(renewed.revision==2 and renewed.rarity=="magic" and renewed.sockets==target.sockets and renewed.upgrade_level==4)
	var rng:=RandomNumberGenerator.new();rng.seed=77
	var generator=preload("res://source/common/gameplay/items/affixes/affix_generator.gd")
	var one: Array=generator.generate(ItemDefinitions.IRON_SWORD,1,0,Rules.PROFILE.pool,rng).affixes
	var augment_target:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,one)
	var full:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,generator.generate(ItemDefinitions.IRON_SWORD,3,3,Rules.PROFILE.pool,rng).affixes)
	var legacy:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,[{"stat":"attack","value":7}])
	assert(db.begin())
	for item: ItemInstance in [augment_target,full,legacy]: assert(Items.new(db).receive_item_in_transaction(item).ok)
	assert(db.commit())
	assert(store.execute(OWNER,0,augment_target.uid,0,currencies[2].uid,0,"craft-complete").ok)
	var augmented: Dictionary=state().filter(func(i: Dictionary)->bool:return i.uid==augment_target.uid)[0]
	assert(augmented.rarity=="magic" and augmented.affixes.size()==2 and augmented.affixes[0]==one[0] and augmented.affixes[1].kind=="suffix")
	var migration_before:=state()
	# Simulate a v1 offline database and rerun the additive migration. No bonus,
	# item revision, UID or socket may be reinterpreted or rerolled.
	assert(db.execute("ALTER TABLE economy.item_instances DROP COLUMN rarity;").ok)
	assert(db.execute("UPDATE economy.schema_versions SET version=1 WHERE feature='npc_shop';").ok)
	assert(Schema.ensure_schema(db))
	assert(state()==migration_before,"migration preserves all UID/value/revision/socket/upgrade data including opaque legacy and six-affix items")
	var rare_empty:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,[]);rare_empty.rarity="rare"
	assert(db.begin() and Items.new(db).receive_item_in_transaction(rare_empty).ok and db.commit())
	assert(state().filter(func(i: Dictionary)->bool:return i.uid==rare_empty.uid)[0].rarity=="rare","explicit rarity is not recomputed from zero affixes")
	var indexed: Dictionary=db.query("SELECT ordinal FROM economy.item_affix_index WHERE uid=:uid;",{"uid":target.uid})
	assert(indexed.ok and indexed.rows.size()==renewed.affixes.size())
	db.close()
	print("POSTGRES_CRAFTING_OK rollback, uncertain COMMIT, replay/conflict, stale race, UID/+level/sockets, migration and auction index")
	get_tree().quit()
