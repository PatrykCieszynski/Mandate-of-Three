extends RefCounted
## S0-only copy of current search semantics, with explicit named bindings.
## Compare projected results/cursors against MarketSearchSqlite; never used by World.
static func build(p: Dictionary) -> Dictionary:
	assert(MarketSearchSqlite.valid(p))
	var where := "s.status='active' AND i.definition_id=:definition AND i.upgrade_level BETWEEN :upgrade_min AND :upgrade_max AND o.price_yang BETWEEN :price_min AND :price_max"
	var params := {"definition":p.definition_id,"upgrade_min":int(p.upgrade_min),"upgrade_max":int(p.upgrade_max),"price_min":int(p.price_min),"price_max":int(p.price_max)}
	for index: int in p.affix_filters.size():
		where += " AND EXISTS(SELECT 1 FROM item_affix_index a WHERE a.uid=i.uid AND a.stat_id=:stat_%d AND a.value>=:minimum_%d)" % [index,index]
		params["stat_%d" % index] = p.affix_filters[index].stat_id
		params["minimum_%d" % index] = p.affix_filters[index].minimum
	var descending: bool = p.sort == "price_desc"
	if not p.cursor.is_empty():
		var cursor: PackedStringArray = p.cursor.split(":")
		# Separate names for repeated equal values: don't rely on driver's alias binding.
		where += " AND (o.price_yang %s :cursor_price OR (o.price_yang=:cursor_equal AND o.offer_id>:cursor_id))" % ("<" if descending else ">")
		params.merge({"cursor_price":int(cursor[0]),"cursor_equal":int(cursor[0]),"cursor_id":cursor[1]})
	params["row_limit"] = int(p.limit)+1
	return {"sql":"SELECT i.*,c.location,c.position AS bag_position,'' AS equipment_slot,o.offer_id,o.shop_id,o.price_yang,o.revision AS offer_revision,s.display_name AS shop_name FROM shop_offers o JOIN account_shops s ON s.shop_id=o.shop_id JOIN item_instances i ON i.uid=o.item_uid JOIN item_custody c ON c.uid=i.uid WHERE "+where+" ORDER BY o.price_yang "+("DESC" if descending else "ASC")+",o.offer_id ASC LIMIT :row_limit;","params":params}

static func project(rows: Array, p: Dictionary, db: SQLite) -> Dictionary:
	assert(OS.get_thread_caller_id()==OS.get_main_thread_id())
	var results: Array = []
	var view := MarketStoreSqlite.new(db)
	for row: Dictionary in rows.slice(0,int(p.limit)):
		var item := view._item_view(row)
		assert(not item.is_empty())
		results.append({"offer_id":row.offer_id,"shop_id":int(row.shop_id),"price":int(row.price_yang),"revision":int(row.offer_revision),"shop_name":row.shop_name,"item":item})
	var cursor := ""
	if rows.size()>int(p.limit):
		var last: Dictionary = rows[int(p.limit)-1]
		cursor = str(int(last.price_yang))+":"+last.offer_id
	return {"ok":true,"results":results,"next_cursor":cursor}
