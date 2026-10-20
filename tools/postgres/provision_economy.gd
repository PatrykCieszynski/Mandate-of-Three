extends SceneTree
## Offline operator command, not invoked by server startup. No data import.
func _initialize() -> void:
	if OS.get_environment("MANDATE_PG_PROVISION")!="1" or OS.get_environment("MANDATE_ECONOMY_CONNECTION").is_empty():
		printerr("Provisioning requires MANDATE_PG_PROVISION=1 and MANDATE_ECONOMY_CONNECTION.")
		quit(1);return
	var database: Object=ClassDB.instantiate("GodotSociDatabase") if ClassDB.class_exists("GodotSociDatabase") else null
	if database==null or not database.open("postgresql",OS.get_environment("MANDATE_ECONOMY_CONNECTION")+" connect_timeout=3"):
		printerr("PostgreSQL provisioning connection failed.");quit(1);return
	var ok: bool=preload("res://source/server/world/database/postgres/economy_schema_postgres.gd").ensure_schema(database)
	if ok:
		var found: Dictionary=database.query("SELECT value FROM economy.meta WHERE key='economy_authority_id';")
		ok=found.ok and found.rows.size()==1
		if ok: print("POSTGRES_ECONOMY_PROVISIONED authority_id=",found.rows[0].value)
	database.close()
	if not ok: printerr("PostgreSQL provisioning failed; inspect the database before retrying.")
	quit(0 if ok else 1)
