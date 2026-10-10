class_name ShopStoreSqlite
extends RefCounted
## Caller supplies server-resolved content, never a client price/item/quantity.
var db: SQLite

func _init(database: SQLite) -> void:
	db = database

func purchase(owner_id: int, pending_yang: int, shop: ShopDefinition, offer_id: StringName, requested_position: int = -1) -> Dictionary:
	if not db.query("BEGIN IMMEDIATE;"): return {"ok":false, "error":"storage"}
	if shop == null or not shop.validation_errors().is_empty(): return _rollback("invalid_definition")
	var offer: ShopOfferDefinition
	for candidate: ShopOfferDefinition in shop.offers:
		if candidate.offer_id == offer_id:
			offer = candidate
			break
	if offer == null: return _rollback("unknown_offer")
	var definition: ItemDefinition = ItemDefinitions.get_definition(offer.item_definition_id)
	var items := ItemStoreSqlite.new(db)
	# Capacity precedes all wallet writes. Explicit targets never fall back.
	var receiving: Dictionary = items.resolve_inventory_position(owner_id, definition.inventory_height, requested_position)
	if not receiving.ok: return _rollback(str(receiving.error))
	var spent: Dictionary = WalletStoreSqlite.new(db).spend_in_transaction(owner_id, pending_yang, offer.price)
	if not spent.ok: return _rollback(str(spent.error))
	var item: ItemInstance = ItemInstance.create(definition, owner_id, [])
	item.amount = offer.quantity
	var inserted: Dictionary = items.receive_item_in_transaction(item, int(receiving.position))
	if not inserted.ok: return _rollback(str(inserted.error))
	if not db.query("COMMIT;"): return _rollback("storage")
	return {"ok":true, "balance":spent.balance, "uid":inserted.uid, "position":inserted.position}

func _rollback(error: String) -> Dictionary:
	db.query("ROLLBACK;")
	return {"ok":false, "error":error}
