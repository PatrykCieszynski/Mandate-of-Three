extends RefCounted
## Opt-in NPC purchase port only. Caller must authorize current NPC/service/range
## before invoking the store, exactly as on SQLite. No client price is accepted.
const Commands = preload("res://source/server/world/database/postgres/economy_command_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const Wallet = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var db: Object
var _transaction: RefCounted
var committed: bool:
	get: return _transaction.committed

func _init(database: Object) -> void:
	db=database
	_transaction=Commands.new(db)

func purchase(owner_id: int, pending_yang: int, shop: ShopDefinition, offer_id: StringName, requested_position: int = -1, operation_id: String = "") -> Dictionary:
	_transaction.committed=false
	if shop==null or not shop.validation_errors().is_empty(): return {"ok":false,"error":"invalid_definition"}
	if not _transaction.begin(owner_id,operation_id,"npc_shop.buy",[owner_id,str(shop.shop_id),str(offer_id),requested_position],true): return _transaction.cached
	var offer: ShopOfferDefinition
	for candidate: ShopOfferDefinition in shop.offers:
		if candidate.offer_id==offer_id:
			offer=candidate
			break
	if offer==null: return _transaction.rollback("unknown_offer")
	var definition:=ItemDefinitions.get_definition(offer.item_definition_id)
	var items:=Items.new(db)
	var receiving:=items.resolve_inventory_position(owner_id,definition.inventory_height,requested_position)
	if not receiving.ok: return _transaction.rollback(str(receiving.error))
	var spent:=Wallet.new(db).spend_in_transaction(_transaction.account_id,pending_yang,offer.price)
	if not spent.ok: return _transaction.rollback(str(spent.error))
	var item:=ItemInstance.create(definition,owner_id,[])
	item.amount=offer.quantity
	var inserted:=items.receive_item_in_transaction(item,int(receiving.position))
	if not inserted.ok: return _transaction.rollback(str(inserted.error))
	return _transaction.commit({"ok":true,"balance":spent.balance,"wallet_states":[spent.wallet_state],"uid":inserted.uid,"position":inserted.position})

func purchase_receipt(owner_id: int, operation_id: String) -> Dictionary:
	if not Commands.valid_id(operation_id): return {"ok":false,"error":"request"}
	var result: Dictionary=db.query("SELECT account_id FROM economy.characters WHERE character_id=:owner;",{"owner":owner_id})
	if not result.ok: return {"ok":false,"error":"storage"}
	if result.rows.is_empty(): return {"ok":false,"error":"owner"}
	result=db.query("SELECT result_json FROM economy.market_commands WHERE account_id=:account AND character_id=:owner AND command_id=:command AND kind='npc_shop.buy';",{"account":result.rows[0].account_id,"owner":owner_id,"command":operation_id})
	if not result.ok: return {"ok":false,"error":"storage"}
	if result.rows.is_empty(): return {"ok":false,"error":"unknown_command"}
	var row: Dictionary=result.rows[0]
	var decoded: Dictionary=Commands.decode(str(row.result_json))
	return decoded if decoded.get("ok",false) else {"ok":false,"error":"storage"}
