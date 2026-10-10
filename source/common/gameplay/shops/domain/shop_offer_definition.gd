class_name ShopOfferDefinition
extends Resource
enum StockPolicy { INFINITE = 0 }
@export var offer_id: StringName
@export var item_definition_id: StringName
@export var quantity: int = 1
@export var price: int = 0
@export var stock_policy: StockPolicy = StockPolicy.INFINITE

func validation_errors() -> Array[String]:
	var errors: Array[String] = []
	if not GameplayContentId.valid(offer_id): errors.append("invalid_offer_id")
	if ItemDefinitions.get_definition(item_definition_id) == null: errors.append("unknown_item")
	if quantity < 1 or quantity > 1000: errors.append("invalid_quantity")
	if price < 0 or price > 9000000000000000: errors.append("invalid_price")
	if stock_policy != StockPolicy.INFINITE: errors.append("invalid_stock_policy")
	return errors
