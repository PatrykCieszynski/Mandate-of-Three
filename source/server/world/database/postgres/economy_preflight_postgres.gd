extends RefCounted
## Read-only startup gate. Provisioning/migration is deliberately separate.
const VERSIONS: Dictionary={"wallet":1,"inventory":1,"inventory_intents":2,"inventory_sessions":1,"npc_shop":1,"storage":1,"shop_seller":1,"shop_settlement":1,"account_claims":1,"auction_search":1,"exchange_ledger":1,"exchange_orders":1}
var db: Object
var committed:=false
var receipt_replay:=false
func _init(database: Object) -> void: db=database

func verify(authority: String) -> Dictionary:
	if not ItemInstance.valid_uid(authority) or db.in_transaction() or not db.begin(): return {"ok":false,"error":"storage"}
	if not db.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;").ok: return _reject("storage")
	var result: Dictionary=db.query("SELECT feature,version FROM economy.schema_versions;",{},64)
	if not result.ok or result.truncated: return _reject("schema")
	var versions: Dictionary={}
	for row: Dictionary in result.rows: versions[str(row.feature)]=int(row.version)
	for feature: String in VERSIONS:
		if versions.get(feature,0)!=VERSIONS[feature]: return _reject("schema")
	result=db.query("SELECT value FROM economy.meta WHERE key='economy_authority_id';")
	if not result.ok: return _reject("storage")
	if result.rows.size()!=1 or result.rows[0].value!=authority: return _reject("authority")
	if not db.commit():
		db.close();return {"ok":false,"error":"storage"}
	return {"ok":true,"authority_id":authority}

func _reject(reason: String) -> Dictionary:
	if not db.rollback(): db.close()
	return {"ok":false,"error":reason}
