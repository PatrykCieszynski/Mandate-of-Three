extends RefCounted
## Shared query semantics and main-thread projection; no connection or admission.
static func build_query(p: Dictionary, postgres: bool = false) -> Dictionary:
	if not MarketRequestRules.valid_search(p): return {"ok":false,"error":"request"}
	var prefix: String="economy." if postgres else ""
	var offer_key: String='o.offer_id COLLATE "C"' if postgres else "o.offer_id"
	var where := "s.status='active' AND i.definition_id=:definition AND i.upgrade_level BETWEEN :upgrade_min AND :upgrade_max AND ((o.offer_only=0 AND o.price_yang BETWEEN :price_min AND :price_max) OR (o.offer_only=1 AND CAST(:negotiable_min AS BIGINT)=0 AND CAST(:negotiable_max AS BIGINT)=9000000000000000))"
	var params := {"definition":p.definition_id,"upgrade_min":int(p.upgrade_min),"upgrade_max":int(p.upgrade_max),"price_min":int(p.price_min),"price_max":int(p.price_max),"negotiable_min":int(p.price_min),"negotiable_max":int(p.price_max)}
	for index: int in p.affix_filters.size():
		where += " AND EXISTS(SELECT 1 FROM "+prefix+"item_affix_index a WHERE a.uid=i.uid AND a.stat_id=:stat_%d AND a.value>=:minimum_%d)" % [index,index]
		params["stat_%d" % index] = p.affix_filters[index].stat_id
		params["minimum_%d" % index] = p.affix_filters[index].minimum
	var descending: bool = p.sort == "price_desc"
	if not p.cursor.is_empty():
		var cursor: PackedStringArray = p.cursor.split(":")
		if cursor.size()!=2 or not cursor[0].is_valid_int() or int(cursor[0])<0 or int(cursor[0])>MarketRequestRules.MAX_YANG or not ItemInstance.valid_uid(cursor[1]): return {"ok":false,"error":"cursor"}
		if int(cursor[0])==0:
			where += " AND o.offer_only=1 AND "+offer_key+">:cursor_id"
			params["cursor_id"] = cursor[1]
		else:
			where += " AND ((o.offer_only=0 AND (o.price_yang %s :cursor_price OR (o.price_yang=:cursor_equal AND " % ("<" if descending else ">")+offer_key+">:cursor_id))) OR o.offer_only=1)"
			params.merge({"cursor_price":int(cursor[0]),"cursor_equal":int(cursor[0]),"cursor_id":cursor[1]})
	params["row_limit"] = int(p.limit)+1
	return {"ok":true,"sql":"SELECT i.*,c.location,c.position AS bag_position,'' AS equipment_slot,o.offer_id,o.shop_id,o.price_yang,o.offer_only,o.revision AS offer_revision,s.display_name AS shop_name FROM "+prefix+"shop_offers o JOIN "+prefix+"account_shops s ON s.shop_id=o.shop_id JOIN "+prefix+"item_instances i ON i.uid=o.item_uid JOIN "+prefix+"item_custody c ON c.uid=i.uid WHERE "+where+" ORDER BY o.offer_only ASC, CASE WHEN o.offer_only=1 THEN 0 ELSE o.price_yang END "+("DESC" if descending else "ASC")+","+offer_key+" ASC LIMIT :row_limit;","params":params}


static func project_rows(rows: Array, p: Dictionary) -> Dictionary:
	assert(OS.get_thread_caller_id()==OS.get_main_thread_id())
	var results: Array = []
	for row: Dictionary in rows.slice(0,int(p.limit)):
		var item := item_view(row)
		if item.is_empty(): return {"ok":false,"error":"unknown_definition"}
		results.append({"offer_id":row.offer_id,"shop_id":int(row.shop_id),"price":null if int(row.offer_only)==1 else int(row.price_yang),"revision":int(row.offer_revision),"shop_name":row.shop_name,"item":item})
	var cursor := ""
	if rows.size()>int(p.limit):
		var last: Dictionary = rows[int(p.limit)-1]
		cursor = str(0 if int(last.offer_only)==1 else int(last.price_yang))+":"+last.offer_id
	return {"ok":true,"results":results,"next_cursor":cursor}

static func item_view(row: Dictionary) -> Dictionary:
	var item:=ItemInstance.from_row(row)
	var definition: ItemDefinition=null if item==null else ItemDefinitions.get_definition(item.definition_id)
	if definition==null: return {}
	var view:=item.to_snapshot()
	view.merge({"item_name":definition.item_name,"icon_id":str(definition.icon_id),"inventory_height":definition.inventory_height,"stats":item.effective_stats(definition)})
	return view
