class_name ItemDefinitions
extends RefCounted

const IRON_SWORD: ItemDefinition = preload("res://source/common/gameplay/items/domain/iron_sword.tres")

const DEV_TRACE_SWORD: ItemDefinition = preload("res://source/common/gameplay/items/domain/dev_trace_sword.tres")

const UPGRADE_ORE: ItemDefinition = preload("res://source/common/gameplay/items/domain/upgrade_ore.tres")

const FOREST_RESIN: ItemDefinition = preload("res://source/common/gameplay/items/domain/forest_resin.tres")
const BEAST_HIDE: ItemDefinition = preload("res://source/common/gameplay/items/domain/beast_hide.tres")
const WOLF_FANG: ItemDefinition = preload("res://source/common/gameplay/items/domain/wolf_fang.tres")
const BANDIT_TOKEN: ItemDefinition = preload("res://source/common/gameplay/items/domain/bandit_token.tres")

const BOOK_AURA: ItemDefinition = preload("res://source/common/gameplay/items/domain/skill_book_aura.tres")
const BOOK_CHARGE: ItemDefinition = preload("res://source/common/gameplay/items/domain/skill_book_charge.tres")
const BOOK_WHIRLWIND: ItemDefinition = preload("res://source/common/gameplay/items/domain/skill_book_whirlwind.tres")
const BOOK_BLESSING: ItemDefinition = preload("res://source/common/gameplay/items/domain/skill_book_blessing.tres")
const BOOK_STRIKE: ItemDefinition = preload("res://source/common/gameplay/items/domain/skill_book_strike.tres")

const CHANGE_SPARK: ItemDefinition=preload("res://source/common/gameplay/items/domain/change_spark.tres")
const RENEWAL_DUST: ItemDefinition=preload("res://source/common/gameplay/items/domain/renewal_dust.tres")
const COMPLETION_SHARD: ItemDefinition=preload("res://source/common/gameplay/items/domain/completion_shard.tres")

## Canonical authored definitions. The same source drives item lookup,
## Exchange's fungible ledger and Auction's searchable tradeable catalog.
## Never infer tradability from the presence of a resource alone.
static func all_definitions() -> Array[ItemDefinition]:
	return [CHANGE_SPARK, RENEWAL_DUST, COMPLETION_SHARD, IRON_SWORD, UPGRADE_ORE, DEV_TRACE_SWORD, FOREST_RESIN, BEAST_HIDE, WOLF_FANG, BANDIT_TOKEN, BOOK_AURA, BOOK_CHARGE, BOOK_WHIRLWIND, BOOK_BLESSING, BOOK_STRIKE]

static func get_definition(id: StringName) -> ItemDefinition:
	for definition: ItemDefinition in all_definitions():
		if id == definition.definition_id: return definition
	return null
