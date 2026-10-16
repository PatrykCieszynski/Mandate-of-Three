extends RefCounted
## Process-lifetime map routing identity; no economic or hosting authority.
static func create(realm: StringName, map: StringName, host: StringName, channel: int) -> Dictionary:
	return {"realm_id":str(realm),"map_id":str(map),"host_id":str(host),"channel_id":channel,
		"instance_id":"map_"+Crypto.new().generate_random_bytes(16).hex_encode()}

static func valid(value: Dictionary) -> bool:
	if value.size()!=5 or not value.has_all(["realm_id","map_id","instance_id","channel_id","host_id"]): return false
	for field: String in ["realm_id","map_id","host_id"]:
		if not value[field] is String or value[field].is_empty() or value[field].length()>96: return false
	if not value.channel_id is int or value.channel_id<0 or not value.instance_id is String or not value.instance_id.begins_with("map_"): return false
	var token: String = value.instance_id.trim_prefix("map_")
	if token.length()!=32: return false
	for character: String in token:
		if not "0123456789abcdef".contains(character): return false
	return true
