extends RefCounted
## Explicit OFFLINE provisioning. Runtime bootstrap never calls this code.
static func ensure_schema(database: Object) -> bool:
	return preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd").ensure_schema(database) and preload("res://source/server/world/database/postgres/auction_search_schema_postgres.gd").ensure_schema(database) and preload("res://source/server/world/database/postgres/exchange_orders_schema_postgres.gd").ensure_schema(database)
