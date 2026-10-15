extends RefCounted
## Client hints only. Server receipts/authorization remain the economic authority.
## Immutable per-intention files avoid replacing another running client's entry.
var directory: String
var _id_prefix: String
var _scope := ""
var _folder := ""
const MAX_BYTES := 4096

func _init(id_prefix: String = "npc-buy-", location: String = "user://pending_npc_purchases") -> void:
	_id_prefix = id_prefix
	directory = location

func configure(context: Dictionary) -> Dictionary:
	_scope = ""
	_folder = ""
	if not ItemInstance.valid_uid(str(context.get("authority_id", ""))) or not context.get("account_id") is int or not context.get("character_id") is int or context.account_id <= 0 or context.character_id <= 0:
		return {"ok":false}
	_scope = ("%s:%d:%d" % [context.authority_id, context.account_id, context.character_id]).sha256_text()
	_folder = ProjectSettings.globalize_path(directory).path_join(_scope)
	if DirAccess.make_dir_recursive_absolute(_folder) != OK: return {"ok":false}
	return load_pending()

func load_pending() -> Dictionary:
	if _folder.is_empty(): return {"ok":false}
	var folder := DirAccess.open(_folder)
	if folder == null: return {"ok":false}
	var files: Array[String] = []
	for name: String in folder.get_files():
		if name.ends_with(".json"): files.append(name)
	# Never pick arbitrarily or erase conflicting/corrupt pending intentions.
	if files.size() > 1: return {"ok":false}
	if files.is_empty(): return {"ok":true,"entry":{}}
	var file := FileAccess.open(_folder.path_join(files[0]), FileAccess.READ)
	if file == null or file.get_length() > MAX_BYTES: return {"ok":false}
	var value: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not value is Dictionary or value.size() != 4 or value.get("version") != 1 or value.get("scope") != _scope or not valid_id(str(value.get("id", ""))) or files[0] != str(value.id) + ".json" or not value.get("payload") is Dictionary:
		return {"ok":false}
	return {"ok":true,"entry":{"id":str(value.id),"payload":value.payload.duplicate(true)}}

func save_pending(id: String, payload: Dictionary) -> bool:
	if not valid_id(id): return false
	var previous := load_pending()
	if not previous.ok or not previous.entry.is_empty(): return false
	var target := _folder.path_join(id + ".json")
	var temporary := target + ".tmp"
	var record := JSON.stringify({"version":1,"scope":_scope,"id":id,"payload":payload})
	if record.to_utf8_buffer().size() > MAX_BYTES: return false
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return false
	file.store_string(record)
	file.flush()
	var written := file.get_error() == OK
	file.close()
	if not written: return false
	# RPC is sent only after close + rename succeeds. A leftover .tmp therefore
	# represents an intention that was never sent and is ignored during restore.
	return DirAccess.rename_absolute(temporary, target) == OK

func clear_pending(id: String) -> bool:
	if _folder.is_empty() or not valid_id(id): return false
	var target := _folder.path_join(id + ".json")
	return not FileAccess.file_exists(target) or DirAccess.remove_absolute(target) == OK

func valid_id(id: String) -> bool:
	return not _id_prefix.is_empty() and id.begins_with(_id_prefix) and ItemInstance.valid_uid(id.trim_prefix(_id_prefix))
