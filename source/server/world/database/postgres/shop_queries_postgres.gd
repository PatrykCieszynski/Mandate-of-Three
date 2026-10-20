extends RefCounted
## Short-lived Shop projections. Public reads never expose revenue or claims.
const Grid = preload("res://source/common/gameplay/items/domain/shop_grid.gd")
var db: Object
var _session: Dictionary={}

func authorize_session(context: Dictionary) -> void: _session=context.duplicate(true)

func _init(database: Object) -> void:
	db=database

func mine(character: int, include_exchange: bool = false) -> Dictionary:
	return _mine(character,true,include_exchange)

## Preserve the existing seller-only projection on pre-claims schemas.
func seller_mine(character: int) -> Dictionary:
	return _mine(character,false)

func _mine(character: int, full_account: bool, include_exchange: bool = false) -> Dictionary:
	if db.in_transaction() or not db.begin(): return _error("storage")
	var identity: Dictionary=db.query("SELECT c.account_id FROM economy.characters c JOIN economy.accounts a ON a.account_id=c.account_id WHERE c.character_id=:id FOR NO KEY UPDATE OF a;",{"id":character})
	if not identity.ok or identity.rows.is_empty(): return _rollback("storage" if not identity.ok else "owner")
	var account: int=int(identity.rows[0].account_id)
	var reason: String=preload("res://source/server/world/database/postgres/inventory_session_postgres.gd").check_in_transaction(db,account,character,_session,false)
	if not reason.is_empty(): return _rollback(reason)
	if not db.execute("INSERT INTO economy.account_shops(account_id) VALUES(:account) ON CONFLICT DO NOTHING;",{"account":account}).ok: return _rollback("storage")
	var shop: Dictionary=db.query("SELECT shop_id FROM economy.account_shops WHERE account_id=:account;",{"account":account})
	if not shop.ok or shop.rows.is_empty(): return _rollback("storage")
	var snapshot:=_shop(int(shop.rows[0].shop_id))
	if not snapshot.ok: return _rollback(str(snapshot.error))
	if full_account:
		var result: Dictionary=db.query("SELECT yang FROM economy.account_shop_revenue WHERE account_id=:account;",{"account":account})
		if not result.ok: return _rollback("storage")
		snapshot.claimable_yang="0" if result.rows.is_empty() else str(result.rows[0].yang)
		snapshot.claims=[]
		result=db.query("SELECT i.*,c.location,-1 AS bag_position,'' AS equipment_slot FROM economy.item_custody c JOIN economy.item_instances i ON i.uid=c.uid WHERE c.location='account_claim' AND c.claim_account_id=:account ORDER BY c.uid LIMIT 200;",{"account":account})
		if not result.ok or result.truncated: return _rollback("storage")
		for row: Dictionary in result.rows:
			var view:=_item_view(row)
			if view.is_empty(): return _rollback("unknown_definition")
			snapshot.claims.append(view)
	if include_exchange:
		snapshot.exchange=preload("res://source/server/world/database/postgres/exchange_orders_postgres.gd").new(db).read_snapshot_in_transaction(character)
		if not snapshot.exchange.ok: return _rollback(str(snapshot.exchange.error))
		snapshot.exchange.exchange_runtime=true
		snapshot.exchange.ledger_only=true
	if not _session.is_empty():
		snapshot.item_state=preload("res://source/server/world/database/postgres/economy_command_postgres.gd").read_state(db,character)
		if snapshot.item_state.is_empty(): return _rollback("storage")
	return _finish(snapshot)

func visit_authorized(context: Dictionary, shop: int) -> Dictionary:
	var begun: Dictionary=preload("res://source/server/world/database/postgres/inventory_session_postgres.gd").new(db).begin_context(context)
	if not begun.ok: return begun
	var snapshot:=_shop(shop)
	if not snapshot.ok: return _rollback(str(snapshot.error))
	snapshot.claims=[]
	return _finish(snapshot)

func visit(shop: int) -> Dictionary:
	if db.in_transaction() or not db.begin(): return _error("storage")
	# Metadata and offers come from one snapshot even when a sale/edit commits
	# between the two SELECTs. No transaction survives a returned projection.
	if not db.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;").ok: return _rollback("storage")
	var snapshot:=_shop(shop)
	if not snapshot.ok: return _rollback(str(snapshot.error))
	# Existing public contract has an empty claims array, no private account data.
	snapshot.claims=[]
	return _finish(snapshot)

func _shop(shop: int) -> Dictionary:
	var result: Dictionary=db.query("SELECT shop_id,display_name AS name,status,revision FROM economy.account_shops WHERE shop_id=:shop;",{"shop":shop})
	if not result.ok: return _error("storage")
	if result.rows.is_empty(): return _error("unavailable")
	var snapshot: Dictionary=result.rows[0].duplicate(true)
	snapshot.merge({"ok":true,"columns":Grid.COLUMNS,"rows":Grid.ROWS,"offers":[]})
	result=db.query("SELECT i.*,c.location,c.position AS bag_position,'' AS equipment_slot,o.offer_id,o.position,o.price_yang,o.offer_only,o.revision AS offer_revision FROM economy.shop_offers o JOIN economy.item_custody c ON c.uid=o.item_uid JOIN economy.item_instances i ON i.uid=o.item_uid WHERE o.shop_id=:shop ORDER BY o.position;",{"shop":shop})
	if not result.ok or result.truncated: return _error("storage")
	for row: Dictionary in result.rows:
		var view:=_item_view(row)
		if view.is_empty(): return _error("unknown_definition")
		snapshot.offers.append({"offer_id":str(row.offer_id),"position":int(row.position),"price":null if int(row.offer_only)==1 else int(row.price_yang),"revision":int(row.offer_revision),"item":view})
	return snapshot

func _item_view(row: Dictionary) -> Dictionary:
	var item:=ItemInstance.from_row(row)
	var definition: ItemDefinition=null if item==null else ItemDefinitions.get_definition(item.definition_id)
	if definition==null: return {}
	var view:=item.to_snapshot()
	view.merge({"item_name":definition.item_name,"icon_id":str(definition.icon_id),"inventory_height":definition.inventory_height,"stats":item.effective_stats(definition)})
	return view

func _rollback(reason: String) -> Dictionary:
	if not db.rollback():
		db.close()
		return _error("storage")
	return _error(reason)

func _finish(snapshot: Dictionary) -> Dictionary:
	if db.commit(): return snapshot
	db.close()
	return {"ok":false,"error":"outcome_unknown","outcome_unknown":true}

func _error(reason: String) -> Dictionary:
	return {"ok":false,"error":reason}
