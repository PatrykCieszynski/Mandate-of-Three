extends Node
const Natural=preload("res://source/common/gameplay/loot/natural_affix_loot.gd")
const Generator=preload("res://source/common/gameplay/items/affixes/affix_generator.gd")
func forced(prefixes: int, suffixes: int) -> Resource:
	var profile: Resource=Natural.DEFAULT.duplicate(true)
	profile.bands.clear();profile.bands.append({"quality":"test","weight":1,"prefixes":prefixes,"suffixes":suffixes})
	return profile
func _ready() -> void:
	var source: Array=[{"definition_id":&"iron_sword","amount":1,"affixes":[]},{"definition_id":&"upgrade_ore","amount":12,"affixes":[]},{"definition_id":ItemDefinitions.BOOK_AURA.definition_id,"amount":1,"affixes":[]}]
	var rng:=RandomNumberGenerator.new();rng.seed=145
	assert(Natural.DEFAULT.valid())
	for count: int in [0,1,2,3]:
		var profile:=forced(count,count)
		var outcome: Dictionary=Natural.resolve(source,rng,profile)
		assert(outcome.ok and outcome.items.size()==source.size())
		assert(outcome.items[0].affixes.size()==count*2 and Generator.validate(outcome.items[0].affixes,ItemDefinitions.IRON_SWORD,profile.pool))
		assert(outcome.items[1]==source[1] and outcome.items[2]==source[2],"materials, stacks and KU remain clean")
		assert(source[0].affixes.is_empty(),"input selection is immutable")
		var ground:=GroundLootSystem.new()
		var uid: String=ground.spawn_resolved_item(Vector3.ZERO,1,"owner",100,ItemDefinitions.IRON_SWORD.definition_id,1,outcome.items[0].affixes)
		assert(not uid.is_empty())
		var item:=GroundLootSystem.prepare_claim_item(uid,1,ground.drops[uid])
		assert(item.uid==uid and item.affixes==outcome.items[0].affixes,"one ground UID freezes its generated effects")
	var high: ItemDefinition=ItemDefinitions.IRON_SWORD.duplicate(true);high.affix_level=5
	var seen_high:=false
	for seed_value: int in 100:
		rng.seed=seed_value
		var outcome: Dictionary=forced(1,1).roll(high,rng)
		for r: Dictionary in outcome.affixes: seen_high=seen_high or r.tier==2
	assert(seen_high,"eligible top tier is available in ordinary two-affix outcomes, not quality-gated")
	var broken:=forced(3,3);broken.pool.pop_back()
	var rejected: Dictionary=Natural.resolve(source,rng,broken)
	assert(rejected.get("error")=="insufficient_pool" and not rejected.has("items"),"bad quality content cannot grant a partial batch")
	assert(Natural.resolve([{"definition_id":&"iron_sword","amount":1,"affixes":[{"stat":"attack","value":1}]}],rng).error=="pre_rolled","never reroll frozen effects")
	# Production caller parity: affix RNG must not alter item drops, Luck, amounts,
	# or the item RNG state later used by party reward selection.
	var resolver:=KillRewardResolver.new();resolver._region_key=&"first_region";resolver._rng.seed=900;resolver._affix_rng.seed=70
	var control:=RandomNumberGenerator.new();control.seed=900
	var death:=MobDeathResult.new();death.mob_key=&"wild_dog";death.category=&"beast";death.spawn_base_loot_rolls=4
	for _n: int in 100:
		var baseline: Dictionary=LootResolver.resolve(LootContent.tables_for(&"first_region",death.category,death.mob_key),4,2500,control)
		var decorated: Dictionary=resolver.resolve_ordinary(death,2500)
		assert(decorated.ok and decorated.attempts==baseline.attempts and decorated.bonus_attempt==baseline.bonus_attempt and decorated.items.size()==baseline.items.size())
		for i: int in baseline.items.size():
			assert(decorated.items[i].definition_id==baseline.items[i].definition_id and decorated.items[i].amount==baseline.items[i].amount)
		assert(control.state==resolver._rng.state,"item-selection RNG stream is unchanged")
	print("NATURAL_AFFIX_LOOT_OK quality counts, top eligible tier, frozen UID and unchanged production loot RNG")
	get_tree().quit()
