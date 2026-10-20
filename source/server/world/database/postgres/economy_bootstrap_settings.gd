extends RefCounted
## Explicit server configuration only. Never place a connection string in world_info.
static func resolve(settings: Dictionary) -> Dictionary:
	var backend: Variant=settings.get("backend","sqlite")
	if backend not in ["sqlite","postgresql"]: return {"ok":false,"error":"backend"}
	if backend=="sqlite": return {"ok":true,"backend":"sqlite"}
	var authority: Variant=settings.get("authority_id")
	var environment: Variant=settings.get("connection_env")
	var capacity: Variant=settings.get("queue_capacity",2)
	if not authority is String or not ItemInstance.valid_uid(authority): return {"ok":false,"error":"authority"}
	if not environment is String or environment.is_empty() or environment.length()>80: return {"ok":false,"error":"connection_env"}
	for character: String in environment:
		if not "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_".contains(character): return {"ok":false,"error":"connection_env"}
	if not capacity is int or capacity<1 or capacity>4: return {"ok":false,"error":"capacity"}
	if OS.get_environment(environment).is_empty(): return {"ok":false,"error":"connection_missing"}
	return {"ok":true,"backend":"postgresql","authority_id":authority,"connection_env":environment,"queue_capacity":capacity}
