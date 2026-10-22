extends RefCounted
## Durable receipt serialization shared by SQL backends; no connection or mutation.
static func encode_result(result: Dictionary) -> String:
	var stored := result.duplicate(true)
	if stored.has("claimed"): stored.claimed=str(stored.claimed)
	if stored.has("item_state"):
		for field: String in ["account_id","character_id","revision"]: stored.item_state[field]=str(stored.item_state[field])
	for state: Dictionary in stored.get("wallet_states",[]):
		for field: String in ["account_id","revision","balance","reserved_yang","pending_applied"]: state[field]=str(state[field])
	return JSON.stringify(stored)

static func decode_result(json: String) -> Dictionary:
	var result: Variant = JSON.parse_string(json)
	if not result is Dictionary: return {"ok":false,"error":"storage"}
	if result.has("claimed"):
		if not result.claimed is String or not result.claimed.is_valid_int(): return {"ok":false,"error":"storage"}
		result.claimed=int(result.claimed)
	if result.has("item_state"):
		if not result.item_state is Dictionary: return {"ok":false,"error":"storage"}
		for field: String in ["account_id","character_id","revision"]:
			var value: Variant = result.item_state.get(field)
			if not value is String or not value.is_valid_int(): return {"ok":false,"error":"storage"}
			result.item_state[field]=int(value)
	if result.has("income_tokens"):
		if not result.income_tokens is Dictionary or result.income_tokens.size()>64: return {"ok":false,"error":"storage"}
		for account: String in result.income_tokens:
			var token: Variant=result.income_tokens[account]
			if not account.is_valid_int() or int(account)<=0 or not token is String or token.length()!=32: return {"ok":false,"error":"storage"}
			for digit: String in token:
				if not "0123456789abcdef".contains(digit): return {"ok":false,"error":"storage"}
	if result.has("wallet_states") and not result.wallet_states is Array: return {"ok":false,"error":"storage"}
	for state: Variant in result.get("wallet_states",[]):
		if not state is Dictionary: return {"ok":false,"error":"storage"}
		if not state.has("revision"): continue # Pre-feature receipt.
		for field: String in ["account_id","revision","balance","reserved_yang","pending_applied"]:
			var value: Variant = state.get(field)
			if not value is String or not value.is_valid_int(): return {"ok":false,"error":"storage"}
			state[field]=int(value)
	return result
