class_name ShopDefinition
extends Resource
@export var shop_id: StringName
@export var display_name: String
@export var currency_id: StringName = &"yang"
@export var offers: Array[ShopOfferDefinition] = []

func validation_errors() -> Array[String]:
	var errors: Array[String] = []
	if not GameplayContentId.valid(shop_id) or display_name.strip_edges().is_empty(): errors.append("invalid_shop")
	if currency_id != &"yang": errors.append("unknown_currency")
	var seen: Dictionary = {}
	for offer: ShopOfferDefinition in offers:
		if offer == null:
			errors.append("null_offer")
			continue
		if seen.has(offer.offer_id): errors.append("duplicate_offer_id")
		seen[offer.offer_id] = true
		errors.append_array(offer.validation_errors())
	return errors
