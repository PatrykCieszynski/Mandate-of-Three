class_name MarketSearchSqlite
extends RefCounted
## Bounded indexed reads. Rolled affixes are projected on mutation, never parsed per search.
const STATS := ItemAffixLabels.STATS
const LOOKUP_SCHEMA_VERSION := 23
var db: SqliteSoci
var last_db_usec := 0
func _init(database: SqliteSoci) -> void: db=database
static func ensure_schema(database: SqliteSoci) -> bool:
	if not database.query("SELECT value FROM meta WHERE key='schema_version';"): return false
	if int(database.query_result[0].value)>=20: return MarketStoreSqlite._ensure_offer_only_column(database)
	if int(database.query_result[0].value)!=19 or not database.query("BEGIN IMMEDIATE;"): return false
	var statements: Array[String]=[
		"CREATE TABLE item_affix_index(uid TEXT NOT NULL REFERENCES item_instances(uid) ON DELETE CASCADE,ordinal INTEGER NOT NULL,stat_id TEXT NOT NULL,value REAL NOT NULL,PRIMARY KEY(uid,ordinal));",
		"CREATE INDEX affix_search ON item_affix_index(stat_id,value,uid);",
		"CREATE INDEX market_item_search ON item_instances(definition_id,upgrade_level,uid);",
		"CREATE INDEX market_price_search ON shop_offers(price_yang,offer_id);",
		"INSERT INTO item_affix_index SELECT i.uid,j.key,json_extract(j.value,'$.stat'),json_extract(j.value,'$.value') FROM item_instances i,json_each(i.affixes_json) j;",
		"CREATE TRIGGER item_affix_insert AFTER INSERT ON item_instances BEGIN INSERT INTO item_affix_index SELECT NEW.uid,j.key,json_extract(j.value,'$.stat'),json_extract(j.value,'$.value') FROM json_each(NEW.affixes_json) j; END;",
		"CREATE TRIGGER item_affix_update AFTER UPDATE OF affixes_json ON item_instances BEGIN DELETE FROM item_affix_index WHERE uid=NEW.uid; INSERT INTO item_affix_index SELECT NEW.uid,j.key,json_extract(j.value,'$.stat'),json_extract(j.value,'$.value') FROM json_each(NEW.affixes_json) j; END;",
		"INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','20');","COMMIT;"
	]
	for statement: String in statements:
		if not database.query(statement):
			database.query("ROLLBACK;");return false
	return MarketStoreSqlite._ensure_offer_only_column(database)
static func ensure_lookup_schema(database: SqliteSoci) -> bool:
	# Run after Exchange v22 and before World admits players/starts any reader.
	if not database.query("SELECT value FROM meta WHERE key='schema_version';"): return false
	if database.query_result.is_empty(): return false
	var version := int(database.query_result[0].value)
	if version >= LOOKUP_SCHEMA_VERSION: return true
	if version != 22 or not database.query("BEGIN IMMEDIATE;"): return false
	for statement: String in [
		"CREATE INDEX IF NOT EXISTS affix_item_lookup ON item_affix_index(uid,stat_id,value);",
		"INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','23');", "COMMIT;"
	]:
		if not database.query(statement):
			database.query("ROLLBACK;");return false
	return true
static func normalize(text: String) -> String:
	var result:=text.to_lower().strip_edges()
	var accented:="ąćęłńóśźżäöüéèêàáâîïôç"
	var plain:="acelnoszzaoueeeaaaiioc"
	for index: int in accented.length(): result=result.replace(accented[index],plain[index])
	return result
static func catalog(query: String) -> Dictionary:
	if query.length()>80: return {"ok":false,"error":"request"}
	var result: Array = []
	var needle: String = normalize(query)
	for definition: ItemDefinition in ItemDefinitions.all_definitions():
		# Match the Shop's sellable policy; never expose dev/quest-bound items.
		if not definition.tradeable:
			continue
		# Empty query is the browser's full tradeable catalog/selector source.
		if needle.is_empty() or needle in normalize(definition.item_name) or needle in normalize(str(definition.definition_id)):
			result.append({"definition_id":str(definition.definition_id),"name":definition.item_name,"icon_id":str(definition.icon_id)})
	return {"ok":true,"items":result,"stats":STATS.duplicate(true)}
static func valid(p: Dictionary) -> bool: return MarketRequestRules.valid_search(p)
func search(p: Dictionary) -> Dictionary:
	var built:=build_query(p)
	if not built.ok: return {"ok":false,"error":built.error}
	var started:=Time.get_ticks_usec()
	if not db.query_with_named_bindings(built.sql,built.params): return {"ok":false,"error":"storage"}
	last_db_usec=Time.get_ticks_usec()-started
	return project_rows(db.query_result.duplicate(true),p,db)

static func build_query(p: Dictionary) -> Dictionary:
	return preload("res://source/server/world/database/auction_search_contract.gd").build_query(p)

static func project_rows(rows: Array, p: Dictionary, _database: SqliteSoci) -> Dictionary:
	return preload("res://source/server/world/database/auction_search_contract.gd").project_rows(rows,p)
