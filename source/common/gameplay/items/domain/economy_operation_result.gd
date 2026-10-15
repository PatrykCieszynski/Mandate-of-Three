class_name EconomyOperationResult
extends RefCounted
## Local application result, never an RPC payload or a durable admission record.
## No live World/player/store references. Business replies keep their wire shape.
var operation_id: String
var character_id: int
var account_id: int
var action: String
var new_commit := false
var receipt_replay := false
var changed_accounts: PackedInt64Array = []
var _response: Dictionary = {}

static func capture(owner: int, account: int, kind: String, id: String, result: Dictionary, committed: bool, affected: Array = []) -> EconomyOperationResult:
	var operation := EconomyOperationResult.new()
	operation.operation_id = id
	operation.character_id = owner
	operation.account_id = account
	operation.action = kind
	operation._response = result.duplicate(true)
	operation.new_commit = committed and bool(result.get("ok", false))
	# For current synchronous Market/Exchange mutations, successful non-commit
	# means receipt replay. Explicit receipt lookup is read-only, not a mutation.
	operation.receipt_replay = kind != "receipt" and bool(result.get("ok", false)) and not operation.new_commit
	if operation.new_commit:
		for value: Variant in affected:
			var affected_id := int(value)
			if affected_id > 0 and not operation.changed_accounts.has(affected_id):
				operation.changed_accounts.append(affected_id)
	return operation

func response() -> Dictionary:
	return _response.duplicate(true)
