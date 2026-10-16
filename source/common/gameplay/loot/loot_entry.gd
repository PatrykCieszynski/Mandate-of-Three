class_name LootEntry
extends Resource
## Absolute per-attempt item probability in basis points; authored content only.
## Actual ground UIDs, owner and mutable item instances belong to World.
@export var item: ItemDefinition
@export_range(0, 10000, 1) var chance_bp: int = 0
@export_range(1, 9999, 1) var min_amount: int = 1
@export_range(1, 9999, 1) var max_amount: int = 1

func valid() -> bool:
	return item != null and ItemDefinitions.get_definition(item.definition_id) == item \
		and chance_bp >= 0 and chance_bp <= 10000 \
		and min_amount >= 1 and max_amount >= min_amount \
		and item.stack_limit >= max_amount
