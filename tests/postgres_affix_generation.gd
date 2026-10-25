extends Node
const Schema=preload("res://source/server/world/database/postgres/auction_search_schema_postgres.gd")
const Items=preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet=preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
const Generator=preload("res://source/common/gameplay/items/affixes/affix_generator.gd")
const Catalog=preload("res://source/common/gameplay/items/affixes/affix_catalog.gd")
func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var db: Object=ClassDB.instantiate("GodotSociDatabase")
	assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")) and Schema.ensure_schema(db))
	assert(Wallet.new(db).initialize_account(16000).ok and Items.new(db).bind_character(160000,16000))
	var rng:=RandomNumberGenerator.new();rng.seed=903
	var pool:=Catalog.definitions()
	pool[2].group=pool[0].group # Same name on opposite sides must survive persistence.
	var rolls: Array=Generator.generate(ItemDefinitions.IRON_SWORD,2,2,pool,rng).affixes
	var generated:=ItemInstance.create(ItemDefinitions.IRON_SWORD,160000,rolls)
	generated.upgrade_level=4;generated.sockets=[{"definition_id":"preserved"}]
	var legacy:=ItemInstance.create(ItemDefinitions.IRON_SWORD,160000,[{"stat":"attack","value":7}])
	assert(db.begin())
	for item: ItemInstance in [generated,legacy]: assert(Items.new(db).receive_item_in_transaction(item).ok)
	assert(db.commit())
	db.close();assert(db.open("postgresql",OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")))
	var snapshot: Dictionary=Items.new(db).inventory(160000)
	assert(snapshot.ok)
	for item: ItemInstance in [generated,legacy]:
		var loaded: Dictionary=snapshot.items.filter(func(i: Dictionary)->bool:return i.uid==item.uid)[0]
		assert(loaded.stats==item.effective_stats(ItemDefinitions.IRON_SWORD) and loaded.sockets==item.sockets and loaded.upgrade_level==item.upgrade_level and loaded.revision==0)
		if item==generated: assert(loaded.affixes==rolls and Generator.validate(loaded.affixes,ItemDefinitions.IRON_SWORD,pool))
		else: assert(loaded.affixes.size()==1 and loaded.affixes[0].value==7 and not loaded.affixes[0].has("affix_version"))
		var indexed: Dictionary=db.query("SELECT ordinal,stat_id,value FROM economy.item_affix_index WHERE uid=:uid ORDER BY ordinal;",{"uid":item.uid})
		assert(indexed.ok and indexed.rows.size()==item.affixes.size())
		for n: int in indexed.rows.size(): assert(indexed.rows[n].stat_id==item.affixes[n].stat and indexed.rows[n].value==item.affixes[n].value,"Auction indexes the unchanged resolved stat/value")
	assert(Items.new(db).inventory_command(160000,"equip",generated.uid,0,-1,"affix-equip").ok)
	var equipped: Dictionary=Items.new(db).inventory(160000)
	var effects:=generated.effective_stats(ItemDefinitions.IRON_SWORD)
	assert(equipped.stats.attack==10+effects.attack and equipped.stats.attack_speed==PlayerResource.BASE_STATS[Stat.ATTACK_SPEED]+effects.attack_speed,"existing equipment projection uses resolved affix effects")
	assert(Items.new(db).inventory_command(160000,"unequip",generated.uid,1,-1,"affix-unequip").ok)
	snapshot=Items.new(db).inventory(160000)
	# Removing/changing an authored pool cannot reinterpret a durable roll.
	var changed_pool:=Catalog.definitions();changed_pool[0].tiers.clear()
	assert(not Generator.validate(rolls,ItemDefinitions.IRON_SWORD,changed_pool))
	assert(Items.new(db).inventory(160000).items==snapshot.items,"reads do not regenerate catalog values")
	db.close()
	print("POSTGRES_AFFIX_GENERATION_OK legacy/new UID, resolved stats, sockets, upgrades, reopen and auction index")
	get_tree().quit()
