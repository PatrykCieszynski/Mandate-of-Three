extends RefCounted
## Illustrative C1 pool only. Not connected to production loot/crafting.
const EXAMPLES: Array=[preload("res://source/common/gameplay/items/affixes/keen.tres"),preload("res://source/common/gameplay/items/affixes/tempered.tres"),preload("res://source/common/gameplay/items/affixes/swift.tres"),preload("res://source/common/gameplay/items/affixes/balanced.tres")]
static func definitions() -> Array:
	var result: Array=[]
	for definition: Resource in EXAMPLES: result.append(definition.duplicate(true))
	return result
