class_name ShopDefinitions
extends RefCounted
const BLACKSMITH_WEAPONS: ShopDefinition = preload("res://source/common/gameplay/shops/domain/blacksmith_weapon_shop.tres")
static func get_definition(id: StringName) -> ShopDefinition:
	return BLACKSMITH_WEAPONS if id == BLACKSMITH_WEAPONS.shop_id else null
