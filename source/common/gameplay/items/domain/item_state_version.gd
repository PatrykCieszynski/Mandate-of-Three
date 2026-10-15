extends RefCounted
## Identity-qualified durable item state, distinct from a live delivery sequence.
static func valid(value: Variant) -> bool:
	return value is Dictionary and value.get("authority_id") is String and value.authority_id.length()==32 and value.authority_id.is_valid_hex_number(false) and value.get("account_id") is int and value.account_id>0 and value.get("character_id") is int and value.character_id>0 and value.get("revision") is int and value.revision>=0

static func accepts(current: Dictionary, candidate: Variant) -> bool:
	if not valid(candidate): return false
	if current.is_empty(): return true
	return candidate.authority_id==current.authority_id and candidate.account_id==current.account_id and candidate.character_id==current.character_id and candidate.revision>=current.revision
