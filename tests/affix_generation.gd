extends Node
const Generator=preload("res://source/common/gameplay/items/affixes/affix_generator.gd")
const Catalog=preload("res://source/common/gameplay/items/affixes/affix_catalog.gd")
const Roll=preload("res://source/common/gameplay/items/affixes/affix_roll.gd")
func _ready() -> void:
	var pool:=Catalog.definitions()
	assert(Generator.valid_pool(pool))
	var base: ItemDefinition=ItemDefinitions.IRON_SWORD.duplicate(true)
	var rng:=RandomNumberGenerator.new();rng.seed=234
	var first: Dictionary=Generator.generate(base,2,2,pool,rng)
	assert(first.ok and Generator.validate(first.affixes,base,pool))
	pool.reverse();rng.seed=234
	assert(Generator.generate(base,2,2,pool,rng)==first,"seed independent of catalog ordering")
	assert(Generator.generate(base,0,0,pool,rng).affixes.is_empty())
	assert(not Generator.generate(base,4,0,pool,rng).ok)
	assert(not Generator.generate(ItemDefinitions.UPGRADE_ORE,1,0,pool,rng).ok)
	var wrong: ItemDefinition=base.duplicate(true);wrong.equipment_slot=&"armor"
	assert(not Generator.generate(wrong,1,0,pool,rng).ok)
	wrong=base.duplicate(true);wrong.affix_family=&"axe"
	assert(not Generator.generate(wrong,1,0,pool,rng).ok)
	var invalid: Array=pool.duplicate();invalid.append(pool[0])
	assert(not Generator.valid_pool(invalid),"duplicate definition IDs rejected")
	var corrupt: Resource=pool[0].duplicate(true);corrupt.tiers[0].weight=-1
	assert(not Generator.valid_pool([corrupt]))
	var seen_tiers: Dictionary={}
	for level: int in [1,5]:
		base.affix_level=level
		for seed_value: int in 100:
			rng.seed=seed_value
			var generated: Dictionary=Generator.generate(base,2,2,pool,rng)
			assert(generated.ok and Generator.validate(generated.affixes,base,pool))
			for r: Dictionary in generated.affixes:
				if level==1: assert(r.tier==1,"ineligible tier never rolls")
				else: seen_tiers[r.tier]=true
	assert(seen_tiers.has(1) and seen_tiers.has(2),"positive tier weights are reachable")
	# Three slots per kind, and symmetric cross-kind exclusion with no partial result.
	var third_prefix: Resource=pool[0].duplicate(true);third_prefix.affix_id=&"test_prefix";third_prefix.kind="prefix";third_prefix.group=&"test_prefix"
	var third_suffix: Resource=pool[0].duplicate(true);third_suffix.affix_id=&"test_suffix";third_suffix.kind="suffix";third_suffix.group=&"test_suffix"
	var expanded: Array=pool+[third_prefix,third_suffix]
	var full: Dictionary=Generator.generate(base,3,3,expanded,rng)
	assert(full.ok and full.affixes.size()==6 and Generator.validate(full.affixes,base,expanded))
	third_prefix.excludes.append(third_suffix.group)
	assert(not Generator.generate(base,3,3,expanded,rng).ok)
	third_prefix.excludes.clear()
	third_suffix.excludes.append(third_prefix.group)
	assert(not Generator.generate(base,3,3,expanded,rng).ok,"exclusion also applies in reverse selection order")
	var tampered: Array=first.affixes.duplicate(true);tampered[0].value=999999
	base.affix_level=1
	assert(not Generator.validate(tampered,base,pool))
	assert(Roll.valid_stored([{"stat":"attack","value":7}]),"legacy bonuses stay valid/unclassified")
	assert(not Roll.valid_stored(first.affixes+[{"stat":"attack","value":7}]),"no implicit legacy conversion")
	assert(not Roll.valid_stored([{"stat":"attack","value":NAN}]))
	# Actual SOCI embedded persistence/reopen, effective stats and existing tooltip.
	var db:=SqliteSoci.new()
	db.path="res://.godot/verification/affix-unit.db"
	assert(db.open_db());WorldSchema.ensure_schema(db)
	var owner: int=EconomyFixture.create_character(WorldStoreSqlite.new(db),"affix-test-"+str(Time.get_ticks_usec()),{"name":"Affix","skin":1})
	var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,owner,first.affixes)
	item.upgrade_level=3;item.sockets=[{"definition_id":"fixture"}]
	var expected:=item.effective_stats(ItemDefinitions.IRON_SWORD)
	assert(db.query("BEGIN IMMEDIATE;") and ItemStoreSqlite.new(db).receive_item_in_transaction(item).ok and db.query("COMMIT;"))
	db.close_db();assert(db.open_db())
	var loaded: Dictionary=ItemStoreSqlite.new(db).inventory(owner).items.filter(func(i: Dictionary)->bool:return i.uid==item.uid)[0]
	assert(loaded.uid==item.uid and loaded.affixes==first.affixes and loaded.stats==expected and loaded.sockets==item.sockets and loaded.upgrade_level==3)
	var tooltip:=ItemUiAdapter.tooltip_details(loaded)
	assert(tooltip.affixes.size()==4 and tooltip.affixes[0].kind==first.affixes[0].kind)
	assert(not ItemUiAdapter.tooltip_details({"affixes":[{"stat":"attack","value":7}]}).affixes[0].has("kind"))
	db.close_db()
	print("AFFIX_GENERATION_OK deterministic eligibility, tiers, exclusions, 3+3, legacy and SOCI reopen")
	get_tree().quit()
