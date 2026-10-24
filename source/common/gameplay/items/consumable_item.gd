class_name ConsumableItem
extends Item
## Legacy profile/item metadata compatibility. Runtime items use ItemDefinition/ItemInstance.


## Flat health restored on use. 0 = this consumable doesn't heal.
## Prototype-simple effect; can later move to a data-driven GameplayEffect list.
@export var heal_amount: int
## Flat mana restored on use. 0 = none.
@export var mana_amount: int
## Optional timed buff (via BuffService): the stat to raise (&"mana_regen",
## &"move_speed", ...). Empty = no buff.
@export var buff_stat: StringName = &""
@export var buff_amount: float = 0.0
@export var buff_duration_s: float = 0.0
## Drink cooldown in ms, SHARED across every item with the same cooldown_category, so
## you can't chain-chug a heal then a mana potion. Recommended 5000-7000 for a real
## gate. Persists across re-equip (banked on Character.ability_cooldowns, like a weapon
## ability's cooldown); resets on logout.
@export var shared_cooldown_ms: int = 6000
## Items sharing this category share ONE drink cooldown. Give a type its own category
## (e.g. &"mana_potion") to make it cool down independently of other potions.
@export var cooldown_category: StringName = &"potion"
## Server roots the drinker in place for this long on use, so you can't run
## and chug at the same time (a sip animation slots in here later). 0 = no
## freeze.
@export var use_freeze_ms: int = 900
## initial charges per single copy if 1 can use the potion one time, if 2 can use the potion 2 times for example.
@export var default_charges: int = 1


func inventory_tab() -> InventoryTab:
	return InventoryTab.CONSUMABLE


func group_key() -> StringName:
	return &"consumables"


func stat_lines() -> Array[Dictionary]:
	var lines: Array[Dictionary] = []
	if heal_amount > 0:
		lines.append({"text": "Restores %d health" % heal_amount, "kind": &"heal"})
	if mana_amount > 0:
		lines.append({"text": "Restores %d mana" % mana_amount, "kind": &"mana"})
	if buff_stat != &"" and not is_zero_approx(buff_amount) and buff_duration_s > 0.0:
		var number: String = ("%+d" % int(buff_amount)) if is_equal_approx(buff_amount, roundf(buff_amount)) else ("%+.1f" % buff_amount)
		var duration: String = ("%dm" % int(buff_duration_s / 60.0)) if buff_duration_s >= 60.0 else ("%ds" % int(buff_duration_s))
		lines.append({"text": "%s %s for %s" % [number, Stat.display_name(buff_stat), duration], "stat": StringName(buff_stat)})
	if default_charges > 1:
		lines.append({"text": "%d charges" % default_charges, "kind": &"charges"})
	return lines
