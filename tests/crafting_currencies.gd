extends Node
const Rules=preload("res://source/common/gameplay/items/crafting/crafting_rules.gd")
const Generator=preload("res://source/common/gameplay/items/affixes/affix_generator.gd")
func _ready() -> void:
	var seen: Dictionary={}
	for seed_value: int in 100:
		var rng:=RandomNumberGenerator.new();rng.seed=seed_value
		var item:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[])
		var result:=Rules.resolve(item,"change_spark",rng)
		assert(result.ok and result.rarity=="magic" and ItemInstance.valid_rarity(result.rarity,result.affixes))
		assert(item.affixes.is_empty() and item.rarity=="normal","pure decisions cannot mutate inputs")
		seen[result.affixes.size()]=true
		item.affixes=result.affixes;item.rarity=result.rarity
		assert(Rules.resolve(item,"change_spark",rng).error=="rarity")
		var renewed:=Rules.resolve(item,"renewal_dust",rng)
		assert(renewed.ok and renewed.rarity=="magic" and Generator.validate(renewed.affixes,ItemDefinitions.IRON_SWORD,Rules.PROFILE.pool))
		if item.affixes.size()==1:
			var original: Dictionary=item.affixes[0].duplicate(true)
			var added:=Rules.resolve(item,"completion_shard",rng)
			assert(added.ok and added.affixes.size()==2 and added.affixes[0]==original and added.affixes[1].kind!=original.kind)
			assert(item.affixes.size()==1)
		else: assert(Rules.resolve(item,"completion_shard",rng).error=="affix_capacity")
	assert(seen.has(1) and seen.has(2))
	var legacy:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[{"stat":"attack","value":7}])
	var rng:=RandomNumberGenerator.new();rng.seed=1
	assert(legacy.rarity=="rare" and Rules.resolve(legacy,"renewal_dust",rng).error=="invalid_affixes")
	var rare:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[]);rare.rarity="rare"
	assert(ItemInstance.valid_rarity("rare",[]) and Rules.resolve(rare,"renewal_dust",rng).error=="rarity","rarity is not affix count")
	assert(not ItemInstance.valid_rarity("normal",legacy.affixes))
	var full: Array=Generator.generate(ItemDefinitions.IRON_SWORD,3,3,Rules.PROFILE.pool,rng).affixes
	assert(ItemInstance.legacy_rarity(full)=="rare" and ItemInstance.valid_rarity("rare",full))
	assert(not Generator.generate(ItemDefinitions.IRON_SWORD,1,0,Rules.PROFILE.pool,rng,full).ok)
	var currency:=ItemInstance.create(ItemDefinitions.CHANGE_SPARK,1,[])
	assert(Rules.resolve(currency,"change_spark",rng).error=="unsupported_item")
	var counts: Dictionary={}
	var splits: Dictionary={}
	for seed_value: int in 120:
		var normal:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[])
		normal.upgrade_level=4;normal.sockets=[{"definition_id":"kept"}]
		var original:=normal.to_snapshot()
		rng.seed=seed_value
		var made:=Rules.resolve(normal,"ascension_ember",rng)
		assert(made.ok and made.rarity=="rare" and made.affixes.size()>=4 and made.affixes.size()<=6)
		assert(Generator.validate(made.affixes,ItemDefinitions.IRON_SWORD,Rules.PROFILE.pool))
		assert(ItemInstance.valid_rarity(made.rarity,made.affixes) and normal.to_snapshot()==original)
		counts[made.affixes.size()]=true
		var prefixes: int=made.affixes.filter(func(a: Dictionary)->bool:return a.kind=="prefix").size()
		splits["%d:%d" % [prefixes,made.affixes.size()-prefixes]]=true
		rng.seed=seed_value
		assert(Rules.resolve(normal,"ascension_ember",rng)==made,"same server seed has the same complete outcome")
		normal.affixes=made.affixes;normal.rarity="rare"
		var before_reroll:=normal.to_snapshot()
		var rerolled:=Rules.resolve(normal,"renewal_prism",rng)
		assert(rerolled.ok and rerolled.rarity=="rare" and ItemInstance.valid_rarity("rare",rerolled.affixes))
		assert(Generator.validate(rerolled.affixes,ItemDefinitions.IRON_SWORD,Rules.PROFILE.pool) and normal.to_snapshot()==before_reroll)
		assert(Rules.resolve(normal,"ascension_ember",rng).error=="rarity")
	assert(counts.size()==3 and splits.size()==6,"exercise every 4/5/6-affix legal split, with at most 3 of each kind")
	var magic:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[full[0]])
	assert(Rules.resolve(magic,"ascension_ember",rng).error=="rarity" and Rules.resolve(magic,"renewal_prism",rng).error=="rarity")
	assert(Rules.resolve(ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[]),"renewal_prism",rng).error=="rarity")
	assert(Rules.resolve(legacy,"renewal_prism",rng).error=="invalid_affixes")
	var tiny_pool: Array=Rules.PROFILE.pool.slice(0,1)
	assert(Rules.resolve(ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[]),"ascension_ember",rng,tiny_pool).error=="insufficient_pool","no downgrade or retry if the authored pool cannot supply Rare")
	assert(Rules.resolve(currency,"ascension_ember",rng).error=="unsupported_item")
	var added_kinds: Dictionary={}
	for prefixes: int in 2:
		for suffixes: int in 2:
			for seed_value: int in 40:
				rng.seed=seed_value
				var retained: Array=Generator.generate(ItemDefinitions.IRON_SWORD,prefixes,suffixes,Rules.PROFILE.pool,rng).affixes
				var initial:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,retained)
				initial.rarity="magic" # Explicit rarity can legally have no rolls.
				initial.upgrade_level=5;initial.sockets=[{"definition_id":"preserve-awaken"}]
				var before:=initial.to_snapshot()
				rng.seed=seed_value
				var awakened:=Rules.resolve(initial,"awakening_seal",rng)
				assert(awakened.ok and awakened.rarity=="rare" and awakened.affixes.size()==retained.size()+1)
				assert(awakened.affixes.slice(0,retained.size())==retained and initial.to_snapshot()==before)
				assert(Generator.validate(awakened.affixes,ItemDefinitions.IRON_SWORD,Rules.PROFILE.pool))
				added_kinds[awakened.affixes[-1].kind]=true
				rng.seed=seed_value
				assert(Rules.resolve(initial,"awakening_seal",rng)==awakened)
	assert(added_kinds.size()==2)
	assert(Rules.resolve(rare,"awakening_seal",rng).error=="rarity")
	assert(Rules.resolve(ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[]),"awakening_seal",rng).error=="rarity")
	assert(Rules.resolve(legacy,"awakening_seal",rng).error=="invalid_affixes")
	# Existing rolls exhaust both kinds. A failed decision must not replace them,
	# silently pick another layout, or promote the original item.
	var restricted: Array=Rules.PROFILE.pool.filter(func(d: Resource)->bool:return d.affix_id in [&"keen",&"swift"])
	var restricted_magic:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,Generator.generate(ItemDefinitions.IRON_SWORD,1,1,restricted,rng).affixes)
	var restricted_before:=restricted_magic.to_snapshot()
	assert(Rules.resolve(restricted_magic,"awakening_seal",rng,restricted).error=="insufficient_pool" and restricted_magic.to_snapshot()==restricted_before)
	for layout: Vector2i in [Vector2i(1,0),Vector2i(1,1),Vector2i(3,3)]:
		var rolls: Array=Generator.generate(ItemDefinitions.IRON_SWORD,layout.x,layout.y,Rules.PROFILE.pool,rng).affixes
		var initial:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,rolls)
		initial.upgrade_level=5;initial.sockets=[{"definition_id":"kept-cleanse"}]
		var original:=initial.to_snapshot()
		var rng_before: int=rng.state
		var clean:=Rules.resolve(initial,"cleansing_salt",rng)
		assert(clean=={"ok":true,"rarity":"normal","affixes":[]} and initial.to_snapshot()==original)
		assert(rng.state==rng_before,"cleanse is deterministic and consumes no random rolls")
		initial.affixes=clean.affixes;initial.rarity=clean.rarity
		var base_only:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[]);base_only.upgrade_level=5
		assert(initial.effective_stats(ItemDefinitions.IRON_SWORD)==base_only.effective_stats(ItemDefinitions.IRON_SWORD),"only affix stats are removed; +level still applies")
		assert(Rules.resolve(initial,"cleansing_salt",rng).error=="rarity")
	assert(Rules.resolve(rare,"cleansing_salt",rng).error=="affix_capacity")
	assert(Rules.resolve(legacy,"cleansing_salt",rng).error=="invalid_affixes","opaque legacy bonuses stay protected")
	assert(Rules.resolve(currency,"cleansing_salt",rng).error=="unsupported_item")
	for prefixes: int in 4:
		for suffixes: int in 4:
			for seed_value: int in 12:
				rng.seed=seed_value
				var retained: Array=Generator.generate(ItemDefinitions.IRON_SWORD,prefixes,suffixes,Rules.PROFILE.pool,rng).affixes
				var initial:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,retained);initial.rarity="rare"
				initial.upgrade_level=4;initial.sockets=[{"definition_id":"kept-extension"}]
				var before:=initial.to_snapshot()
				rng.seed=seed_value
				var extended:=Rules.resolve(initial,"completion_core",rng)
				assert(initial.to_snapshot()==before)
				if prefixes==3 and suffixes==3:
					assert(extended.error=="affix_capacity")
					continue
				assert(extended.ok and extended.rarity=="rare" and extended.affixes.size()==retained.size()+1)
				assert(extended.affixes.slice(0,retained.size())==retained and Generator.validate(extended.affixes,ItemDefinitions.IRON_SWORD,Rules.PROFILE.pool))
				if prefixes==3: assert(extended.affixes[-1].kind=="suffix")
				if suffixes==3: assert(extended.affixes[-1].kind=="prefix")
				rng.seed=seed_value
				assert(Rules.resolve(initial,"completion_core",rng)==extended)
	restricted_magic.rarity="rare"
	assert(Rules.resolve(restricted_magic,"completion_core",rng,restricted).error=="insufficient_pool")
	assert(Rules.resolve(legacy,"completion_core",rng).error=="invalid_affixes")
	assert(Rules.resolve(magic,"completion_core",rng).error=="rarity")
	assert(Rules.resolve(ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[]),"completion_core",rng).error=="rarity")
	for layout: Vector2i in [Vector2i(1,0),Vector2i(1,1),Vector2i(3,1),Vector2i(3,3)]:
		var rolls: Array=Generator.generate(ItemDefinitions.IRON_SWORD,layout.x,layout.y,Rules.PROFILE.pool,rng).affixes
		var initial:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,rolls)
		initial.upgrade_level=5;initial.sockets=[{"definition_id":"kept-prune"}]
		var before:=initial.to_snapshot()
		var possible: Array=[]
		for index: int in rolls.size():
			var survivors: Array=rolls.duplicate(true);survivors.remove_at(index);possible.append(survivors)
		var seen_removed: Dictionary={}
		for seed_value: int in 100:
			rng.seed=seed_value
			var pruned:=Rules.resolve(initial,"dispersal_chisel",rng)
			assert(pruned.ok and pruned.rarity==initial.rarity and pruned.affixes.size()==rolls.size()-1 and pruned.affixes in possible)
			assert(initial.to_snapshot()==before and Generator.validate(pruned.affixes,ItemDefinitions.IRON_SWORD,Rules.PROFILE.pool))
			seen_removed[possible.find(pruned.affixes)]=true
			rng.seed=seed_value
			assert(Rules.resolve(initial,"dispersal_chisel",rng)==pruned)
		assert(seen_removed.size()==rolls.size(),"every roll can be removed, including both kinds and the last Magic affix")
	assert(Rules.resolve(rare,"dispersal_chisel",rng).error=="affix_capacity")
	assert(Rules.resolve(legacy,"dispersal_chisel",rng).error=="invalid_affixes")
	assert(Rules.resolve(ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[]),"dispersal_chisel",rng).error=="rarity")
	print("CRAFTING_CURRENCIES_OK explicit rarity, preservation, extension, removal, cleanse, legacy refusal, caps")
	get_tree().quit()
