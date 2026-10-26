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
	for definition: ItemDefinition in [ItemDefinitions.CHANGE_SPARK,ItemDefinitions.RENEWAL_DUST,ItemDefinitions.COMPLETION_SHARD,ItemDefinitions.ASCENSION_EMBER,ItemDefinitions.RENEWAL_PRISM,ItemDefinitions.AWAKENING_SEAL,ItemDefinitions.CLEANSING_SALT,ItemDefinitions.COMPLETION_CORE,ItemDefinitions.DISPERSAL_CHISEL,ItemDefinitions.ATTUNEMENT_PRISM]:
		var item:=ItemInstance.create(definition,OWNER,[]);item.amount=2 if definition==ItemDefinitions.CLEANSING_SALT else 20;currencies.append(item)
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
	augment_target.upgrade_level=2;augment_target.sockets=[{"definition_id":"kept-magic"}]
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
	var rare_target:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,[])
	rare_target.upgrade_level=5;rare_target.sockets=[{"definition_id":"preserved-rare"}]
	assert(db.begin() and Items.new(db).receive_item_in_transaction(rare_target).ok and db.commit())
	var rare_before:=state()
	assert(store.execute(OWNER,0,rare_target.uid,0,currencies[4].uid,0,"rare-wrong-rarity").error=="rarity" and state()==rare_before)
	# The same rollback/unknown outcome guarantee applies to creating Rare.
	assert(db.execute("CREATE CONSTRAINT TRIGGER craft_fault AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
	assert(store.execute(OWNER,0,rare_target.uid,0,currencies[3].uid,0,"rare-unknown").get("outcome_unknown",false))
	assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
	assert(state()==rare_before)
	assert(db.execute("DROP TRIGGER craft_fault ON economy.market_commands;").ok)
	store=Craft.new(db)
	var created:=store.execute(OWNER,0,rare_target.uid,0,currencies[3].uid,0,"rare-create")
	assert(created.ok and store.committed and created.rarity=="rare" and created.affixes.size()>=4 and created.affixes.size()<=6)
	var created_state:=state()
	var rare_saved: Dictionary=created_state.filter(func(i: Dictionary)->bool:return i.uid==rare_target.uid)[0]
	assert(rare_saved.upgrade_level==5 and rare_saved.sockets==rare_target.sockets and rare_saved.bag_position==rare_before.filter(func(i: Dictionary)->bool:return i.uid==rare_target.uid)[0].bag_position)
	assert(created_state.filter(func(i: Dictionary)->bool:return i.uid==currencies[3].uid)[0].amount==19)
	assert(db.execute("CREATE TRIGGER craft_fault BEFORE UPDATE OF affixes_json ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
	assert(store.execute(OWNER,0,rare_target.uid,1,currencies[4].uid,0,"rare-reroll-fault").error=="storage" and state()==created_state)
	assert(db.execute("DROP TRIGGER craft_fault ON economy.item_instances;").ok)
	var reforged:=store.execute(OWNER,0,rare_target.uid,1,currencies[4].uid,0,"rare-reforge")
	assert(reforged.ok and reforged.rarity=="rare" and reforged.affixes.size()>=4 and reforged.affixes.size()<=6)
	var final_state:=state()
	assert(final_state.filter(func(i: Dictionary)->bool:return i.uid==currencies[4].uid)[0].amount==19)
	assert(store.execute(OWNER,0,rare_target.uid,1,currencies[4].uid,0,"rare-reforge")==reforged and store.receipt_replay)
	assert(store.execute(OWNER,0,rare_target.uid,0,currencies[3].uid,0,"rare-create")==created and store.receipt_replay and state()==final_state,"old creation receipt never rolls back a later reforge")
	assert(store.execute(OWNER,0,rare_target.uid,1,currencies[4].uid,0,"rare-stale").error=="stale" and state()==final_state)
	assert(store.execute(OWNER,0,legacy.uid,0,currencies[4].uid,1,"rare-legacy").error=="invalid_affixes" and state()==final_state)
	var final_target: Dictionary=final_state.filter(func(i: Dictionary)->bool:return i.uid==rare_target.uid)[0]
	assert(final_target.revision==2 and final_target.upgrade_level==5 and final_target.sockets==rare_target.sockets and final_target.affixes==reforged.affixes)
	assert(db.query("SELECT ordinal FROM economy.item_affix_index WHERE uid=:uid;",{"uid":rare_target.uid}).rows.size()==reforged.affixes.size())
	# Promotion starts with the completed Magic item. Original ordered affixes,
	# values and identity survive; only the appended roll and rarity are new.
	var promote_before:=state()
	var magic_before: Dictionary=promote_before.filter(func(i: Dictionary)->bool:return i.uid==augment_target.uid)[0]
	assert(db.execute("CREATE TRIGGER craft_fault BEFORE UPDATE OF affixes_json ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
	assert(store.execute(OWNER,0,augment_target.uid,1,currencies[5].uid,0,"awaken-write-fault").error=="storage" and state()==promote_before)
	assert(db.execute("DROP TRIGGER craft_fault ON economy.item_instances;").ok)
	assert(db.execute("CREATE CONSTRAINT TRIGGER craft_fault AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
	assert(store.execute(OWNER,0,augment_target.uid,1,currencies[5].uid,0,"awaken-unknown").get("outcome_unknown",false))
	assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and state()==promote_before)
	assert(db.execute("DROP TRIGGER craft_fault ON economy.market_commands;").ok)
	store=Craft.new(db)
	var awakened:=store.execute(OWNER,0,augment_target.uid,1,currencies[5].uid,0,"awaken-paid")
	assert(awakened.ok and store.committed and awakened.rarity=="rare" and awakened.affixes.size()==magic_before.affixes.size()+1)
	assert(awakened.affixes.slice(0,magic_before.affixes.size())==magic_before.affixes)
	var promoted_state:=state()
	var promoted: Dictionary=promoted_state.filter(func(i: Dictionary)->bool:return i.uid==augment_target.uid)[0]
	assert(promoted.upgrade_level==magic_before.upgrade_level and promoted.sockets==magic_before.sockets and promoted.bag_position==magic_before.bag_position and promoted.revision==2)
	assert(promoted_state.filter(func(i: Dictionary)->bool:return i.uid==currencies[5].uid)[0].amount==19)
	assert(store.execute(OWNER,0,augment_target.uid,1,currencies[5].uid,0,"awaken-paid")==awakened and store.receipt_replay and state()==promoted_state)
	assert(store.execute(OWNER,0,augment_target.uid,2,currencies[5].uid,1,"awaken-twice").error=="rarity" and state()==promoted_state)
	assert(store.execute(OWNER,0,augment_target.uid,1,currencies[5].uid,0,"awaken-stale").error=="stale" and state()==promoted_state)
	assert(db.query("SELECT ordinal FROM economy.item_affix_index WHERE uid=:uid;",{"uid":augment_target.uid}).rows.size()==awakened.affixes.size())
	var cleanse_receipts: Array=[]
	var cleanse_revision: int=0
	for item: ItemInstance in [target,rare_target]:
		var before_cleanse:=state()
		var saved_before: Dictionary=before_cleanse.filter(func(i: Dictionary)->bool:return i.uid==item.uid)[0]
		var id: String="cleanse-"+str(cleanse_revision)
		assert(db.execute("CREATE TRIGGER craft_fault BEFORE UPDATE OF affixes_json ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
		assert(store.execute(OWNER,0,item.uid,2,currencies[6].uid,cleanse_revision,id+"-write").error=="storage" and state()==before_cleanse)
		assert(db.execute("DROP TRIGGER craft_fault ON economy.item_instances;").ok)
		assert(db.execute("CREATE CONSTRAINT TRIGGER craft_fault AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
		assert(store.execute(OWNER,0,item.uid,2,currencies[6].uid,cleanse_revision,id+"-unknown").get("outcome_unknown",false))
		assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and state()==before_cleanse)
		assert(db.execute("DROP TRIGGER craft_fault ON economy.market_commands;").ok)
		store=Craft.new(db)
		var cleared:=store.execute(OWNER,0,item.uid,2,currencies[6].uid,cleanse_revision,id)
		assert(cleared.ok and store.committed and cleared.rarity=="normal" and cleared.affixes.is_empty())
		var after_cleanse:=state()
		var saved_after: Dictionary=after_cleanse.filter(func(i: Dictionary)->bool:return i.uid==item.uid)[0]
		assert(saved_after.uid==item.uid and saved_after.revision==3 and saved_after.upgrade_level==saved_before.upgrade_level and saved_after.sockets==saved_before.sockets and saved_after.bag_position==saved_before.bag_position)
		var base_only:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,[]);base_only.upgrade_level=saved_before.upgrade_level
		assert(saved_after.stats==base_only.effective_stats(ItemDefinitions.IRON_SWORD))
		assert(db.query("SELECT ordinal FROM economy.item_affix_index WHERE uid=:uid;",{"uid":item.uid}).rows.is_empty())
		assert(store.execute(OWNER,0,item.uid,2,currencies[6].uid,cleanse_revision,id)==cleared and store.receipt_replay and state()==after_cleanse)
		cleanse_receipts.append(cleared)
		if cleanse_revision==0:
			assert(after_cleanse.filter(func(i: Dictionary)->bool:return i.uid==currencies[6].uid)[0].amount==1)
			assert(store.execute(OWNER,0,item.uid,3,currencies[6].uid,1,"cleanse-normal").error=="rarity" and state()==after_cleanse)
			assert(store.execute(OWNER,0,legacy.uid,0,currencies[6].uid,1,"cleanse-legacy").error=="invalid_affixes" and state()==after_cleanse)
		cleanse_revision+=1
	var exhausted:=state()
	assert(exhausted.filter(func(i: Dictionary)->bool:return i.uid==currencies[6].uid).is_empty())
	assert(store.execute(OWNER,0,target.uid,2,currencies[6].uid,0,"cleanse-0")==cleanse_receipts[0] and store.receipt_replay and state()==exhausted,"replay works after the last currency was consumed")
	for side: int in 2:
		var retained: Array=full.affixes.slice(0,5) if side==0 else full.affixes.slice(1)
		var extension_target:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,retained)
		extension_target.upgrade_level=6;extension_target.sockets=[{"definition_id":"kept-extension"}]
		assert(db.begin() and Items.new(db).receive_item_in_transaction(extension_target).ok and db.commit())
		var before_extension:=state()
		var saved_before: Dictionary=before_extension.filter(func(i: Dictionary)->bool:return i.uid==extension_target.uid)[0]
		var id: String="extend-"+str(side)
		assert(db.execute("CREATE TRIGGER craft_fault BEFORE UPDATE OF affixes_json ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
		assert(store.execute(OWNER,0,extension_target.uid,0,currencies[7].uid,side,id+"-write").error=="storage" and state()==before_extension)
		assert(db.execute("DROP TRIGGER craft_fault ON economy.item_instances;").ok)
		assert(db.execute("CREATE CONSTRAINT TRIGGER craft_fault AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
		assert(store.execute(OWNER,0,extension_target.uid,0,currencies[7].uid,side,id+"-unknown").get("outcome_unknown",false))
		assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and state()==before_extension)
		assert(db.execute("DROP TRIGGER craft_fault ON economy.market_commands;").ok)
		store=Craft.new(db)
		var extended:=store.execute(OWNER,0,extension_target.uid,0,currencies[7].uid,side,id)
		assert(extended.ok and store.committed and extended.rarity=="rare" and extended.affixes.size()==6 and extended.affixes.slice(0,5)==retained)
		assert(extended.affixes[-1].kind==("suffix" if side==0 else "prefix"))
		var after_extension:=state()
		var saved_after: Dictionary=after_extension.filter(func(i: Dictionary)->bool:return i.uid==extension_target.uid)[0]
		assert(saved_after.revision==1 and saved_after.uid==extension_target.uid and saved_after.upgrade_level==6 and saved_after.sockets==extension_target.sockets and saved_after.bag_position==saved_before.bag_position)
		assert(after_extension.filter(func(i: Dictionary)->bool:return i.uid==currencies[7].uid)[0].amount==19-side)
		assert(store.execute(OWNER,0,extension_target.uid,0,currencies[7].uid,side,id)==extended and store.receipt_replay and state()==after_extension)
		assert(store.execute(OWNER,0,extension_target.uid,1,currencies[7].uid,side+1,id+"-full").error=="affix_capacity" and state()==after_extension)
		assert(store.execute(OWNER,0,extension_target.uid,0,currencies[7].uid,side,id+"-stale").error=="stale" and state()==after_extension)
		assert(db.query("SELECT ordinal FROM economy.item_affix_index WHERE uid=:uid;",{"uid":extension_target.uid}).rows.size()==6)
	for side: int in 2:
		var rolls: Array=generator.generate(ItemDefinitions.IRON_SWORD,1 if side==0 else 3,0 if side==0 else 3,Rules.PROFILE.pool,rng).affixes
		var removal_target:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,rolls)
		removal_target.upgrade_level=7;removal_target.sockets=[{"definition_id":"kept-removal"}]
		assert(db.begin() and Items.new(db).receive_item_in_transaction(removal_target).ok and db.commit())
		var before_removal:=state()
		var saved_before: Dictionary=before_removal.filter(func(i: Dictionary)->bool:return i.uid==removal_target.uid)[0]
		var id: String="remove-"+str(side)
		assert(db.execute("CREATE TRIGGER craft_fault BEFORE UPDATE OF affixes_json ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
		assert(store.execute(OWNER,0,removal_target.uid,0,currencies[8].uid,side,id+"-write").error=="storage" and state()==before_removal)
		assert(db.execute("DROP TRIGGER craft_fault ON economy.item_instances;").ok)
		assert(db.execute("CREATE CONSTRAINT TRIGGER craft_fault AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
		assert(store.execute(OWNER,0,removal_target.uid,0,currencies[8].uid,side,id+"-unknown").get("outcome_unknown",false))
		assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and state()==before_removal)
		assert(db.execute("DROP TRIGGER craft_fault ON economy.market_commands;").ok)
		store=Craft.new(db)
		var pruned:=store.execute(OWNER,0,removal_target.uid,0,currencies[8].uid,side,id)
		assert(pruned.ok and store.committed and pruned.rarity==removal_target.rarity and pruned.affixes.size()==rolls.size()-1)
		var legal_survivors: Array=[]
		for index: int in rolls.size():
			var survivors: Array=rolls.duplicate(true);survivors.remove_at(index);legal_survivors.append(survivors)
		assert(pruned.affixes in legal_survivors,"exactly one removal; other values, tiers and order survive")
		var after_removal:=state()
		var saved_after: Dictionary=after_removal.filter(func(i: Dictionary)->bool:return i.uid==removal_target.uid)[0]
		assert(saved_after.revision==1 and saved_after.uid==removal_target.uid and saved_after.upgrade_level==7 and saved_after.sockets==removal_target.sockets and saved_after.bag_position==saved_before.bag_position)
		assert(after_removal.filter(func(i: Dictionary)->bool:return i.uid==currencies[8].uid)[0].amount==19-side)
		assert(store.execute(OWNER,0,removal_target.uid,0,currencies[8].uid,side,id)==pruned and store.receipt_replay and state()==after_removal,"receipt never removes another roll")
		assert(store.execute(OWNER,0,removal_target.uid,0,currencies[8].uid,side,id+"-stale").error=="stale" and state()==after_removal)
		if side==0: assert(store.execute(OWNER,0,removal_target.uid,1,currencies[8].uid,1,"remove-empty").error=="affix_capacity" and state()==after_removal)
		assert(db.query("SELECT ordinal FROM economy.item_affix_index WHERE uid=:uid;",{"uid":removal_target.uid}).rows.size()==pruned.affixes.size())
	for side: int in 2:
		var rolls: Array=generator.generate(ItemDefinitions.IRON_SWORD,1 if side==0 else 3,1 if side==0 else 3,Rules.PROFILE.pool,rng).affixes
		var tuning_target:=ItemInstance.create(ItemDefinitions.IRON_SWORD,OWNER,rolls)
		tuning_target.upgrade_level=8;tuning_target.sockets=[{"definition_id":"kept-values"}]
		assert(db.begin() and Items.new(db).receive_item_in_transaction(tuning_target).ok and db.commit())
		var before_tuning:=state()
		var id: String="attune-"+str(side)
		assert(db.execute("CREATE TRIGGER craft_fault BEFORE UPDATE OF affixes_json ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
		assert(store.execute(OWNER,0,tuning_target.uid,0,currencies[9].uid,side,id+"-write").error=="storage" and state()==before_tuning)
		assert(db.execute("DROP TRIGGER craft_fault ON economy.item_instances;").ok)
		assert(db.execute("CREATE CONSTRAINT TRIGGER craft_fault AFTER INSERT ON economy.market_commands DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.craft_fault();").ok)
		assert(store.execute(OWNER,0,tuning_target.uid,0,currencies[9].uid,side,id+"-unknown").get("outcome_unknown",false))
		assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and state()==before_tuning)
		assert(db.execute("DROP TRIGGER craft_fault ON economy.market_commands;").ok)
		store=Craft.new(db)
		var tuned:=store.execute(OWNER,0,tuning_target.uid,0,currencies[9].uid,side,id)
		assert(tuned.ok and store.committed and tuned.rarity==tuning_target.rarity and tuned.affixes.size()==rolls.size())
		assert(preload("res://source/common/gameplay/items/affixes/affix_generator.gd").validate(tuned.affixes,ItemDefinitions.IRON_SWORD,Rules.PROFILE.pool))
		for index: int in rolls.size():
			var original: Dictionary=rolls[index].duplicate(true);var tuned_meta: Dictionary=tuned.affixes[index].duplicate(true)
			original.erase("value");tuned_meta.erase("value");assert(original==tuned_meta)
		var after_tuning:=state()
		var saved_after: Dictionary=after_tuning.filter(func(i: Dictionary)->bool:return i.uid==tuning_target.uid)[0]
		assert(saved_after.revision==1 and saved_after.uid==tuning_target.uid and saved_after.upgrade_level==8 and saved_after.sockets==tuning_target.sockets and saved_after.bag_position==before_tuning.filter(func(i: Dictionary)->bool:return i.uid==tuning_target.uid)[0].bag_position)
		assert(after_tuning.filter(func(i: Dictionary)->bool:return i.uid==currencies[9].uid)[0].amount==19-side)
		assert(store.execute(OWNER,0,tuning_target.uid,0,currencies[9].uid,side,id)==tuned and store.receipt_replay and state()==after_tuning)
		assert(store.execute(OWNER,0,tuning_target.uid,0,currencies[9].uid,side,id+"-stale").error=="stale" and state()==after_tuning)
		var indexed_values: Dictionary=db.query("SELECT ordinal,value FROM economy.item_affix_index WHERE uid=:uid ORDER BY ordinal;",{"uid":tuning_target.uid})
		assert(indexed_values.ok and indexed_values.rows.size()==tuned.affixes.size())
		for index: int in indexed_values.rows.size(): assert(indexed_values.rows[index].value==tuned.affixes[index].value)
	db.close()
	print("POSTGRES_CRAFTING_OK rollback, uncertain COMMIT, replay/conflict, stale race, UID/+level/sockets, migration and auction index")
	get_tree().quit()
