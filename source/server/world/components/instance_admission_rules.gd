class_name InstanceAdmissionRules
extends RefCounted
## Shared, 2D-independent admission predicates. No Player, Map or RPC types.

static func allows_character(character_id: int, access_policy: int, allowed_ids: PackedInt64Array) -> bool:
	return character_id > 0 and (
		access_policy == 0
		or (access_policy == 1 and allowed_ids.has(character_id))
	)

static func accepts_reservation(is_deleting: bool, admission_state: int, population: int, capacity: int) -> bool:
	return not is_deleting and admission_state == 0 and population < capacity
