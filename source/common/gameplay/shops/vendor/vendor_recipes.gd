class_name VendorRecipes
extends RefCounted
const RECYCLE: VendorRecipeDefinition = preload("res://source/common/gameplay/shops/vendor/recycle_skill_books.tres")

static func definitions() -> Array[VendorRecipeDefinition]: return [RECYCLE]

static func pools() -> Dictionary:
	return {"random_skill_book":{"icon_id":"mystery_skill_book","items":["skill_book_aura","skill_book_charge","skill_book_whirlwind","skill_book_blessing","skill_book_strike"]}}

## Includes prices, tags and pool membership; quote validation never relies on
## a manually bumped version alone. Registry order is authored and stable.
static func version() -> String:
	var data: Array=[1,pools()]
	for recipe: VendorRecipeDefinition in definitions():
		data.append([recipe.recipe_id,recipe.priority,recipe.inputs,recipe.reward_pool,recipe.reward_quantity])
	for item: ItemDefinition in ItemDefinitions.all_definitions():
		data.append([item.definition_id,item.vendor_price,item.recipe_tags,item.recipe_category,item.inventory_height,item.stack_limit])
	return JSON.stringify(data).sha256_text()
