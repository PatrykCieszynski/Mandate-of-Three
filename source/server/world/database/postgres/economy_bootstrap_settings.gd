extends RefCounted
## Explicit server configuration only. Never place a connection string in world_info.
static func load_config(path: String) -> Dictionary:
	var config:=ConfigFile.new()
	if config.load(path)!=OK: return {"ok":false,"error":"config"}
	var settings: Dictionary={}
	if config.has_section("economy"):
		for key: String in config.get_section_keys("economy"): settings[key]=config.get_value("economy",key)
	var result:=resolve(settings)
	if result.ok and result.backend=="postgresql":
		result["profile_path"]=settings.get("profile_path","")
		result["realm_state"]=settings.get("realm_state",false)
	return result

static func resolve(settings: Dictionary) -> Dictionary:
	var backend: Variant=settings.get("backend","sqlite")
	if backend not in ["sqlite","postgresql"]: return {"ok":false,"error":"backend"}
	if not settings.get("realm_state",false) is bool: return {"ok":false,"error":"realm_state"}
	if settings.get("realm_state",false) and backend!="postgresql": return {"ok":false,"error":"realm_state_backend"}
	if backend=="sqlite": return {"ok":true,"backend":"sqlite"}
	var authority: Variant=settings.get("authority_id",OS.get_environment(str(settings.get("authority_env","MANDATE_ECONOMY_AUTHORITY_ID"))))
	var environment: Variant=settings.get("connection_env")
	var capacity: Variant=settings.get("queue_capacity",2)
	if not authority is String or not ItemInstance.valid_uid(authority): return {"ok":false,"error":"authority"}
	if not environment is String or environment.is_empty() or environment.length()>80: return {"ok":false,"error":"connection_env"}
	for character: String in environment:
		if not "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_".contains(character): return {"ok":false,"error":"connection_env"}
	if not capacity is int or capacity<1 or capacity>4: return {"ok":false,"error":"capacity"}
	if OS.get_environment(environment).is_empty(): return {"ok":false,"error":"connection_missing"}
	return {"ok":true,"backend":"postgresql","authority_id":authority,"connection_env":environment,"queue_capacity":capacity}
