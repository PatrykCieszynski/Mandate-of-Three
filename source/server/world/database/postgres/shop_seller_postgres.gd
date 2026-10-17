extends RefCounted
## Seller-only port; purchase/revenue/claims/search remain separate milestones.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Grid = preload("res://source/common/gameplay/items/domain/shop_grid.gd")
const MAX_PRICE: int=9000000000000000
var db: Object
var _transaction: RefCounted
var rejected: MarketRejectedCommands
var committed: bool:
	get: return _transaction.committed

func _init(database: Object, rejected_commands: MarketRejectedCommands = null) -> void:
	db=database
	rejected=rejected_commands if rejected_commands!=null else MarketRejectedCommands.new()
	_transaction=Commands.new(db,rejected)

## Retain the seller-only projection on its original schema.
func mine(character: int) -> Dictionary:
	return preload("res://source/server/world/database/postgres/shop_queries_postgres.gd").new(db).seller_mine(character)

func list_item(character: int, command: String, uid: String, revision: int, position: int, price: int) -> Dictionary:
	if not _transaction.begin(character,command,"list",[uid,revision,position,price],true): return _transaction.cached
	if not ItemInstance.valid_uid(uid) or revision<0 or price<0 or price>MAX_PRICE: return _reject("request")
	var result: Dictionary=db.query(Items.ITEM_SELECT+"WHERE i.uid=:uid AND i.owner_character_id=:owner AND c.owner_id=:owner AND c.location='bag';",{"uid":uid,"owner":character})
	if not result.ok: return _transaction.rollback("storage")
	if result.rows.is_empty(): return _reject("owner")
	var item:=ItemInstance.from_row(result.rows[0])
	if item==null: return _reject("invalid_item")
	if item.revision!=revision: return _reject("stale")
	var definition:=ItemDefinitions.get_definition(item.definition_id)
	if definition==null or not definition.tradeable or item.amount>definition.stack_limit: return _reject("not_tradeable")
	var cells:=Grid.cells(position,definition.inventory_height)
	if cells.is_empty(): return _reject("placement")
	var shop: int=_shop(_transaction.account_id)
	if shop==0: return _transaction.rollback("storage")
	var available:=_available(shop,cells,"")
	if not available.ok: return _transaction.rollback("storage")
	if not available.available: return _reject("occupied")
	var offer: String=Crypto.new().generate_random_bytes(16).hex_encode()
	if not db.execute("UPDATE economy.item_custody SET location='shop_escrow',escrow_account_id=:account,position=:position,shop_id=:shop,offer_id=:offer WHERE uid=:uid;",{"account":_transaction.account_id,"position":position,"shop":shop,"offer":offer,"uid":uid}).ok: return _transaction.rollback("storage")
	if not db.execute("INSERT INTO economy.shop_offers(offer_id,shop_id,account_id,item_uid,position,price_yang,offer_only) VALUES(:offer,:shop,:account,:uid,:position,:price,:only);",{"offer":offer,"shop":shop,"account":_transaction.account_id,"uid":uid,"position":position,"price":maxi(price,1),"only":1 if price==0 else 0}).ok: return _transaction.rollback("storage")
	if not _place_cells(shop,uid,cells) or not _revision(uid): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"offer_id":offer,"uid":uid,"revision":0,"shop_id":shop})

func cancel_offer(character: int, command: String, offer: String, revision: int) -> Dictionary:
	# Preserve the existing account-scoped fingerprint, including cross-alt retries.
	if not _transaction.begin(character,command,"cancel",[offer,revision],true): return _transaction.cached
	var found:=_offer(offer)
	if not found.ok: return _transaction.rollback("storage")
	if found.rows.is_empty(): return _reject("unavailable")
	var row: Dictionary=found.rows[0]
	if int(row.revision)!=revision: return _reject("stale")
	var definition:=ItemDefinitions.get_definition(StringName(row.definition_id))
	if definition==null: return _reject("unknown_definition")
	var receiving:=Items.new(db).resolve_inventory_position(character,definition.inventory_height,-1)
	if not receiving.ok: return _reject(str(receiving.error))
	if not _remove_cells(str(row.item_uid)): return _transaction.rollback("storage")
	if not db.execute("UPDATE economy.item_instances SET owner_character_id=:owner,revision=revision+1 WHERE uid=:uid;",{"owner":character,"uid":row.item_uid}).ok: return _transaction.rollback("storage")
	if not db.execute("UPDATE economy.item_custody SET location='bag',owner_id=:owner,position=:position,escrow_account_id=NULL,shop_id=NULL,offer_id=NULL WHERE uid=:uid;",{"owner":character,"position":receiving.position,"uid":row.item_uid}).ok: return _transaction.rollback("storage")
	if not db.execute("DELETE FROM economy.shop_offers WHERE offer_id=:offer;",{"offer":offer}).ok: return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"uid":str(row.item_uid),"position":int(receiving.position)})

func configure(character: int, command: String, revision: int, name: String, status: String) -> Dictionary:
	if not _transaction.begin(character,command,"configure",[revision,name,status],true): return _transaction.cached
	if name.strip_edges().is_empty() or name.length()>40 or status not in ["active","paused"]: return _reject("request")
	for letter: String in name:
		if letter.unicode_at(0)<32: return _reject("request")
	var shop: int=_shop(_transaction.account_id)
	if shop==0: return _transaction.rollback("storage")
	var row: Dictionary=db.query("SELECT revision FROM economy.account_shops WHERE shop_id=:shop;",{"shop":shop})
	if not row.ok or row.rows.is_empty(): return _transaction.rollback("storage")
	if int(row.rows[0].revision)!=revision: return _reject("stale")
	if not db.execute("UPDATE economy.account_shops SET display_name=:name,status=:status,revision=revision+1 WHERE shop_id=:shop;",{"name":name.strip_edges(),"status":status,"shop":shop}).ok: return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"revision":revision+1})

func edit_offer(character: int, command: String, offer: String, revision: int, position: int, price: int) -> Dictionary:
	if not _transaction.begin(character,command,"edit",[offer,revision,position,price],true): return _transaction.cached
	if price<0 or price>MAX_PRICE: return _reject("request")
	var found:=_offer(offer)
	if not found.ok: return _transaction.rollback("storage")
	if found.rows.is_empty(): return _reject("unavailable")
	var row: Dictionary=found.rows[0]
	if int(row.revision)!=revision: return _reject("stale")
	var definition:=ItemDefinitions.get_definition(StringName(row.definition_id))
	if definition==null: return _reject("unknown_definition")
	var cells:=Grid.cells(position,definition.inventory_height)
	if cells.is_empty(): return _reject("placement")
	var available:=_available(int(row.shop_id),cells,str(row.item_uid))
	if not available.ok: return _transaction.rollback("storage")
	if not available.available: return _reject("occupied")
	if not _remove_cells(str(row.item_uid)): return _transaction.rollback("storage")
	if not db.execute("UPDATE economy.item_custody SET position=:position WHERE uid=:uid;",{"position":position,"uid":row.item_uid}).ok: return _transaction.rollback("storage")
	if not db.execute("UPDATE economy.shop_offers SET position=:position,price_yang=:price,offer_only=:only,revision=revision+1 WHERE offer_id=:offer;",{"position":position,"price":maxi(price,1),"only":1 if price==0 else 0,"offer":offer}).ok: return _transaction.rollback("storage")
	if not _place_cells(int(row.shop_id),str(row.item_uid),cells): return _transaction.rollback("storage")
	if position!=int(row.position) and not _revision(str(row.item_uid)): return _transaction.rollback("storage")
	return _transaction.commit({"ok":true,"revision":revision+1})

## Existing Shop receipt discovery is account-scoped, not issuer-scoped.
func receipt(character: int, command: String) -> Dictionary:
	if not Commands.valid_id(command): return _error("request")
	var state:=Items.new(db).read_state(character)
	if state.is_empty(): return _error("owner")
	var result: Dictionary=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND command_id=:command;",{"account":state.account_id,"command":command})
	if not result.ok: return _error("storage")
	if not result.rows.is_empty(): return Commands.decode(str(result.rows[0].result_json))
	var cached:=rejected.receipt(int(state.account_id),command)
	return cached if not cached.is_empty() else _error("unknown_command")

func _shop(account: int) -> int:
	if not db.execute("INSERT INTO economy.account_shops(account_id) VALUES(:account) ON CONFLICT DO NOTHING;",{"account":account}).ok: return 0
	var result: Dictionary=db.query("SELECT shop_id FROM economy.account_shops WHERE account_id=:account;",{"account":account})
	return int(result.rows[0].shop_id) if result.ok and not result.rows.is_empty() else 0

func _offer(offer: String) -> Dictionary:
	return db.query("SELECT o.*,i.definition_id FROM economy.shop_offers o JOIN economy.item_instances i ON i.uid=o.item_uid WHERE o.offer_id=:offer AND o.account_id=:account;",{"offer":offer,"account":_transaction.account_id})

func _available(shop: int, cells: Array[int], excluded: String) -> Dictionary:
	for cell: int in cells:
		var result: Dictionary=db.query("SELECT 1 FROM economy.shop_cells WHERE shop_id=:shop AND position=:position AND item_uid<>:excluded;",{"shop":shop,"position":cell,"excluded":excluded})
		if not result.ok: return {"ok":false}
		if not result.rows.is_empty(): return {"ok":true,"available":false}
	return {"ok":true,"available":true}

func _place_cells(shop: int, uid: String, cells: Array[int]) -> bool:
	for cell: int in cells:
		if not db.execute("INSERT INTO economy.shop_cells(shop_id,position,item_uid) VALUES(:shop,:position,:uid);",{"shop":shop,"position":cell,"uid":uid}).ok: return false
	return true

func _remove_cells(uid: String) -> bool:
	return db.execute("DELETE FROM economy.shop_cells WHERE item_uid=:uid;",{"uid":uid}).ok

func _revision(uid: String) -> bool:
	return db.execute("UPDATE economy.item_instances SET revision=revision+1 WHERE uid=:uid;",{"uid":uid}).ok

func _reject(reason: String) -> Dictionary:
	return _transaction.commit(_error(reason))

func _error(reason: String) -> Dictionary:
	return {"ok":false,"error":reason}
