extends RefCounted
## Durable account item watermark. Row changes, not business-command counts.
## Triggers share every writer's transaction, including trusted grants and custody.
static func ensure_schema(db: SqliteSoci) -> bool:
	if not db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='item_custody';"): return false
	var canonical := not db.query_result.is_empty()
	var feature_version := "2" if canonical else "1"
	if not db.query("SELECT value FROM meta WHERE key='item_state_revision_schema';"): return false
	if not db.query_result.is_empty() and str(db.query_result[0].value)==feature_version: return true
	if not db.query("BEGIN IMMEDIATE;"): return false
	var statements: Array[String] = ["CREATE TABLE IF NOT EXISTS account_item_revisions(account_name TEXT PRIMARY KEY NOT NULL,revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>=0));"]
	# v19 replaces the legacy placement/storage tables with views. Install on the
	# actual custody table after that migration, preserving existing watermarks.
	for table: String in ["item_instances","item_placements","account_storage","item_custody"]:
		for event: String in ["insert","update","delete"]: statements.append("DROP TRIGGER IF EXISTS item_revision_%s_%s;" % [table,event])
	var tables: Array = ["item_instances","item_custody"] if canonical else ["item_instances","item_placements","account_storage"]
	for table: String in tables:
		for event: String in ["INSERT","UPDATE","DELETE"]:
			var references: Array[String] = []
			if event != "INSERT": references.append("OLD")
			if event != "DELETE": references.append("NEW")
			var queries: Array[String] = []
			for reference: String in references:
				if table=="account_storage": queries.append("SELECT %s.account_name AS account_name" % reference)
				elif table=="item_custody":
					queries.append("SELECT account_name FROM players WHERE %s.location IN ('bag','equipment') AND player_id=%s.owner_id" % [reference,reference])
					queries.append("SELECT account_name FROM accounts WHERE %s.location IN ('account_storage','shop_escrow','account_claim') AND master_account_id=%s.owner_id" % [reference,reference])
				else: queries.append("SELECT account_name FROM players WHERE player_id=%s.owner_character_id" % reference)
			var accounts := " UNION ".join(queries)
			var guard := ""
			if event=="UPDATE":
				var columns: Array = {"item_instances":["uid","owner_character_id","definition_id","amount","upgrade_level","affixes_json","sockets_json","revision"],"item_custody":["uid","location","owner_id","position","equipment_slot","container_id","offer_id"],"item_placements":["item_uid","owner_character_id","location","bag_position","equipment_slot"],"account_storage":["item_uid","account_name","position"]}[table]
				var changed: Array[String] = []
				for column: String in columns: changed.append("OLD.%s IS NOT NEW.%s" % [column,column])
				guard = " WHEN "+" OR ".join(changed)
			# UNION deduplicates old/new account on updates; WHERE disambiguates UPSERT.
			statements.append("CREATE TRIGGER item_revision_%s_%s AFTER %s ON %s%s BEGIN INSERT INTO account_item_revisions(account_name,revision) SELECT account_name,1 FROM (%s) WHERE true ON CONFLICT(account_name) DO UPDATE SET revision=revision+1; END;" % [table,event.to_lower(),event,table,guard,accounts])
	statements.append("INSERT OR REPLACE INTO meta(key,value) VALUES('item_state_revision_schema','%s');" % feature_version)
	statements.append("COMMIT;")
	for statement: String in statements:
		if not db.query(statement):
			db.query("ROLLBACK;")
			return false
	return true

static func read(db: SqliteSoci, character_id: int) -> Dictionary:
	if not db.query_with_bindings("SELECT m.value AS authority_id,a.master_account_id AS account_id,COALESCE(r.revision,0) AS revision FROM players p JOIN accounts a ON a.account_name=p.account_name LEFT JOIN account_item_revisions r ON r.account_name=p.account_name JOIN meta m ON m.key='economy_authority_id' WHERE p.player_id=?;",[character_id]) or db.query_result.is_empty(): return {}
	var row: Dictionary = db.query_result[0]
	return {"authority_id":str(row.authority_id),"account_id":int(row.account_id),"character_id":character_id,"revision":int(row.revision)}
