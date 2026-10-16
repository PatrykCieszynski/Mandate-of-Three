class_name LootTable
extends Resource
## A reusable authored source. Global/region/category/mob scopes are selected by World.
@export var entries: Array[LootEntry] = []

func valid() -> bool:
	for entry: LootEntry in entries:
		if entry == null or not entry.valid():
			return false
	return true
