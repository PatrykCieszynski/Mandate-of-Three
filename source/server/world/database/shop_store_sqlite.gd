class_name ShopStoreSqlite
extends RefCounted
## Caller supplies server-resolved content, never a client price/item/quantity.
var db: SQLite
var _transaction: EconomyCommandSqlite
var committed: bool:
	get: return _transaction.committed

func _init(database: SQLite, rejected_commands: MarketRejectedCommands = null) -> void:
	db = database
	_transaction = EconomyCommandSqlite.new(db, rejected_commands)

func purchase(owner_id: int, pending_yang: int, shop: ShopDefinition, offer_id: StringName, requested_position: int = -1, operation_id: String = "") -> Dictionary:
	_transaction.committed = false
	if shop == null or not shop.validation_errors().is_empty(): return {"ok":false, "error":"invalid_definition"}
	# Character is part of the intention: another character on the same account
	# cannot replay a purchase into a different receiving inventory.
	if not _transaction.begin(owner_id, operation_id, "npc_shop.buy", [owner_id, str(shop.shop_id), str(offer_id), requested_position]): return _transaction.cached
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
	var account_id := WorldStoreSqlite.new(db).resolve_account_id(owner_id)
	var spent: Dictionary = WalletStoreSqlite.new(db).spend_in_transaction(account_id, pending_yang, offer.price)
	if not spent.ok: return _rollback(str(spent.error))
	var item: ItemInstance = ItemInstance.create(definition, owner_id, [])
	item.amount = offer.quantity
	var inserted: Dictionary = items.receive_item_in_transaction(item, int(receiving.position))
	if not inserted.ok: return _rollback(str(inserted.error))
	return _transaction.commit({"ok":true, "balance":spent.balance, "uid":inserted.uid, "position":inserted.position})

func _rollback(error: String) -> Dictionary:
	return _transaction.rollback(error)
