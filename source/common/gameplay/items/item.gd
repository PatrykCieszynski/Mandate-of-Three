class_name Item
extends Resource
## Legacy profile/item metadata compatibility. Runtime items use ItemDefinition/ItemInstance.


## Which bag tab an item belongs to. Canonical — the inventory UI must never
## classify by `is`-type checks (that made Materials a fragile negation bucket).
## Weapons/tools (equip + act) and armor (silent stat buffers) are deliberately
## separate tabs (owner call, 2026-07-16).
enum InventoryTab {
	WEAPON,
	ARMOR,
	CONSUMABLE,
	MATERIAL,
	QUEST,
	OTHER,
}


# Definition
@export var item_name: StringName = &"ItemDefault"
@export var item_icon: Texture2D
@export_multiline var description: String

## Can this item be drawn into the player's HAND (shown off, and tapped to act if it has
## an action)? True for nearly everything — set false only for items that should never be
## wielded. Gear ignores it (armor equips to its body slot via its own path); this gates
## plain items (materials, trophies) and consumables.
@export var holdable: bool = true

# Trading / Economy
## Marks this item as a currency (gold, event tokens, ...). Currency items are paid
## with / received in transactions, shown in the wallet, and hidden from the bag grid.
@export var is_currency: bool = false
## Can trade for goods between players.
@export var can_trade: bool = false
## Can sell to the consigment house.
## Minimum price the item can be sold at consigment house.
## If 0 any price can be choosen.
## This is not shop price. If an item is sold at a shop, the price is defined in shop logic.
@export var market_minimum_price: int = 0


# Inventory
## If 0 no limit.
## 0 = pseudo infinite stack size
## 1 = non-stackable
@export_range(0, 99, 1.0) var stack_limit: int = 0
## Optional free-form tags for filters/crafting
@export var tags: PackedStringArray = []


func is_stackable() -> bool:
	return stack_limit == 0 or stack_limit > 1


## Which bag tab this item lives in. Subclasses override; plain items land in
## OTHER, which the UI folds into Materials.
func inventory_tab() -> InventoryTab:
	return InventoryTab.OTHER


## Section heading key within a tab (&"weapons" / &"armor" / ...). Groups only —
## labels and group ORDER are the UI's concern. Subclasses override.
func group_key() -> StringName:
	return &"items"


## Deterministic ordering inside a section. The UI sorts by group order, then
## this array element-wise, then slot uid — so identical items always sit
## together. Entries must be same-typed across items sharing a group_key.
func sort_key() -> Array:
	return [String(item_name)]


## Human-readable stat lines for tooltips, auto-generated from the item's REAL data
## (never from the hand-written description), so changing a stat never needs a copy
## edit. Base items (materials, currency) have none. Subclasses override. Mirrors
## QuestObjective.describe().
## Each entry is {"text": String} plus a semantic tag the tooltip colours by:
## either "stat": <Stat key> (a modifier) or "kind": &"weapon"/"level"/"heal"/
## "mana"/"charges". The data layer stays presentation-free; colours live in the UI.
func stat_lines() -> Array[Dictionary]:
	return []
