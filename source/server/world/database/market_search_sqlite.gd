class_name MarketSearchSqlite
extends RefCounted
## Bounded indexed reads. Rolled affixes are projected on mutation, never parsed per search.
const STATS := ItemAffixLabels.STATS
const LOOKUP_SCHEMA_VERSION := 23
var db: SQLite
var last_db_usec := 0
func _init(database: SQLite) -> void: db=database
static func ensure_schema(database: SQLite) -> bool:
	if not database.query("SELECT value FROM meta WHERE key='schema_version';"): return false
	if int(database.query_result[0].value)>=20: return true
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
	return true
static func ensure_lookup_schema(database: SQLite) -> bool:
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
	var result: Array=[]
	for definition: ItemDefinition in [ItemDefinitions.IRON_SWORD,ItemDefinitions.UPGRADE_ORE]:
		if normalize(query) in normalize(definition.item_name) or normalize(query) in normalize(str(definition.definition_id)):
			result.append({"definition_id":str(definition.definition_id),"name":definition.item_name,"icon_id":str(definition.icon_id)})
	return {"ok":true,"items":result,"stats":STATS.duplicate(true)}
static func valid(p: Dictionary) -> bool: return MarketRequestRules.valid_search(p)
func search(p: Dictionary) -> Dictionary:
	if not valid(p): return {"ok":false,"error":"request"}
	var where:="s.status='active' AND i.definition_id=? AND i.upgrade_level BETWEEN ? AND ? AND o.price_yang BETWEEN ? AND ?"
	var args: Array=[p.definition_id,int(p.upgrade_min),int(p.upgrade_max),int(p.price_min),int(p.price_max)]
	for filter: Dictionary in p.affix_filters:
		where+=" AND EXISTS(SELECT 1 FROM item_affix_index a WHERE a.uid=i.uid AND a.stat_id=? AND a.value>=?)"
		args.append(filter.stat_id);args.append(filter.minimum)
	var desc: bool=p.sort=="price_desc"
	if not p.cursor.is_empty():
		var cursor: PackedStringArray=p.cursor.split(":")
		if cursor.size()!=2 or not cursor[0].is_valid_int() or int(cursor[0])<1 or int(cursor[0])>WalletStoreSqlite.MAX_YANG or not ItemInstance.valid_uid(cursor[1]): return {"ok":false,"error":"cursor"}
		where+=" AND (o.price_yang %s ? OR (o.price_yang=? AND o.offer_id>?))" % ("<" if desc else ">")
		args.append(int(cursor[0]));args.append(int(cursor[0]));args.append(cursor[1])
	var sql:="SELECT i.*,c.location,c.position AS bag_position,'' AS equipment_slot,o.offer_id,o.shop_id,o.price_yang,o.revision AS offer_revision,s.display_name AS shop_name FROM shop_offers o JOIN account_shops s ON s.shop_id=o.shop_id JOIN item_instances i ON i.uid=o.item_uid JOIN item_custody c ON c.uid=i.uid WHERE "+where+" ORDER BY o.price_yang "+("DESC" if desc else "ASC")+",o.offer_id ASC LIMIT ?;"
	args.append(int(p.limit)+1)
	var db_started := Time.get_ticks_usec()
	if not db.query_with_bindings(sql,args): return {"ok":false,"error":"storage"}
	last_db_usec = Time.get_ticks_usec()-db_started
	var rows:=db.query_result.duplicate(true)
	var result: Array=[]
	var view:=MarketStoreSqlite.new(db)
	for row: Dictionary in rows.slice(0,int(p.limit)):
		var item:=view._item_view(row)
		if item.is_empty(): return {"ok":false,"error":"unknown_definition"}
		result.append({"offer_id":row.offer_id,"shop_id":row.shop_id,"price":row.price_yang,"revision":row.offer_revision,"shop_name":row.shop_name,"item":item})
	var next:=""
	if rows.size()>int(p.limit):
		var last: Dictionary=rows[int(p.limit)-1];next=str(last.price_yang)+":"+last.offer_id
	return {"ok":true,"results":result,"next_cursor":next}
