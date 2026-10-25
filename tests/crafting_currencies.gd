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
	print("CRAFTING_CURRENCIES_OK explicit rarity, one/two rolls, preserved augmentation, legacy refusal, caps")
	get_tree().quit()
