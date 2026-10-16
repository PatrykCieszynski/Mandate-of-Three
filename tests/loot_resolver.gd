extends Node
## Reproducible Loot V2 contracts without dependency on a running World or SQL.
func make_entry(item: ItemDefinition, chance: int, minimum: int = 1, maximum: int = 1) -> LootEntry:
	var entry := LootEntry.new()
	entry.item = item
	entry.chance_bp = chance
	entry.min_amount = minimum
	entry.max_amount = maximum
	return entry

func make_table(raw_entries: Array) -> LootTable:
	var result := LootTable.new()
	var entries: Array[LootEntry] = []
	for entry: LootEntry in raw_entries:
		entries.append(entry)
	result.entries = entries
	return result

func roll(tables: Array, base_count: int, luck_bp: int, seed_value: int = 987) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return LootResolver.resolve(tables, base_count, luck_bp, rng)

func _ready() -> void:
	var ore := ItemDefinitions.UPGRADE_ORE
	var sword := ItemDefinitions.IRON_SWORD
	var global_entry := make_entry(ore, 50, 2, 4)
	var region_entry := make_entry(ore, 300)
	var category_entry := make_entry(ore, 800)
	var mob_entry := make_entry(sword, 200)
	var tables := [
		make_table([global_entry]), make_table([region_entry]),
		make_table([category_entry]), make_table([mob_entry])
	]
	var outcome := roll(tables, 1, 0)
	assert(outcome.ok and outcome.pool_weight_bp == 1350 and outcome.attempts == 1)
	assert(not outcome.bonus_attempt and outcome.items.size() <= 1)
	assert(outcome == roll(tables, 1, 0), "Identical RNG seed must reproduce the outcomes")

	# Optional sources and an empty table do not create bonus rolls.
	var empty := roll([null, null, null, null], 4, 10000)
	assert(empty.ok and empty.items.is_empty() and empty.attempts == 5 and empty.bonus_attempt)
	var no_drop := roll([make_table([make_entry(ore, 0)])], 4, 0)
	assert(no_drop.ok and no_drop.items.is_empty())

	# Repeat the same item definition across attempts, each outcome still independent.
	var guaranteed := make_table([make_entry(ore, 10000, 2, 4)])
	var always := roll([guaranteed], 4, 10000)
	assert(always.ok and always.items.size() == 5 and always.attempts == 5)
	for item: Dictionary in always.items:
		assert(item.definition_id == ore.definition_id and item.amount >= 2 and item.amount <= 4)
		assert(item.affixes.is_empty() and not item.has("uid"), "Ground UID belongs to a later stage")
	var fixed := roll([guaranteed], 2, 0)
	assert(fixed.ok and fixed.items.size() == 2 and fixed.attempts == 2)

	# The four scopes share one fixed probability budget, with no renormalization.
	var overflow := [make_table([make_entry(ore, 6000)]), make_table([make_entry(sword, 5000)])]
	assert(roll(overflow, 1, 0).error == "probability_overflow")
	var exactly_full := roll([make_table([make_entry(sword, 10000)]), make_table([make_entry(ore, 0)])], 1, 0)
	assert(exactly_full.ok and exactly_full.items.size() == 1)
	assert(exactly_full.items[0].definition_id == sword.definition_id)

	var fake_ore := ore.duplicate() as ItemDefinition
	var broken := [
		make_entry(ore, -1),
		make_entry(ore, 50, 1, 201),
		make_entry(sword, 50, 1, 2),
		make_entry(fake_ore, 50)
	]
	for entry: LootEntry in broken:
		assert(not entry.valid())
		assert(roll([make_table([entry])], 1, 0).error == "entry")
	assert(roll([42], 1, 0).error == "table")
	assert(roll(tables, 0, 0).error == "attempts")
	assert(roll(tables, 5, 0).error == "attempts")
	assert(roll(tables, 1, -1).error == "luck")
	assert(roll(tables, 1, 10001).error == "luck")
	assert(not LootResolver.resolve(tables, 1, 0, null).ok)

	# Luck is a single bonus chance, independent of the number of base draws.
	assert(roll([guaranteed], 4, 0).items.size() == 4)
	assert(roll([guaranteed], 4, 10000).items.size() == 5)
	var twenty := roll([guaranteed], 4, 2000)
	assert(twenty.ok and twenty.attempts >= 4 and twenty.attempts <= 5)
	print("LOOT_RESOLVER_OK: combined sources, empty outcomes, quantity, 1..4 draws and one Luck draw")
	get_tree().quit()
