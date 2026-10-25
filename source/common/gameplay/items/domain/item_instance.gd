class_name ItemInstance
extends RefCounted

var uid: String
var definition_id: StringName
var owner_character_id: int
var amount: int = 1
var upgrade_level: int = 0
var affixes: Array = []
var rarity: String = "normal"
var sockets: Array = []
var revision: int = 0
var location: String = "bag"
var bag_position: int = 0
var equipment_slot: StringName = &""

## Shared wire/domain format only. Ownership and revision remain server checks.
static func valid_uid(value: String) -> bool:
	if value.length() != 32:
		return false
	for character: String in value:
		if not "0123456789abcdef".contains(character):
			return false
	return true

static func create(definition: ItemDefinition, owner_id: int, rolls: Array) -> ItemInstance:
	var item := ItemInstance.new()
	item.uid = Crypto.new().generate_random_bytes(16).hex_encode()
	item.definition_id = definition.definition_id
	item.owner_character_id = owner_id
	item.affixes = rolls.duplicate(true)
	item.rarity = legacy_rarity(rolls)
	return item

func effective_stats(definition: ItemDefinition) -> Dictionary:
	var result: Dictionary = definition.base_stats.duplicate()
	for stat: StringName in definition.stats_per_upgrade:
		result[stat] = float(result.get(stat, 0)) + definition.stats_per_upgrade[stat] * upgrade_level
	for affix: Dictionary in affixes:
		var stat: StringName = StringName(affix.get("stat", ""))
		if result.has(stat):
			result[stat] = float(result[stat]) + float(affix.get("value", 0))
	return result

func to_snapshot() -> Dictionary:
	return {"uid": uid, "definition_id": str(definition_id), "owner_character_id": owner_character_id,
		"amount": amount, "upgrade_level": upgrade_level, "rarity":rarity, "affixes": affixes.duplicate(true),
		"sockets": sockets.duplicate(true), "revision": revision, "location": location,
		"bag_position": bag_position, "equipment_slot": str(equipment_slot)}

static func from_row(row: Dictionary) -> ItemInstance:
	var item := ItemInstance.new()
	item.uid = str(row.uid)
	item.definition_id = StringName(row.definition_id)
	item.owner_character_id = int(row.owner_character_id)
	item.amount = int(row.amount)
	item.upgrade_level = int(row.upgrade_level)
	item.revision = int(row.revision)
	item.location = str(row.location)
	item.bag_position = int(row.bag_position)
	item.equipment_slot = StringName(row.equipment_slot)
	var rolls: Variant = JSON.parse_string(str(row.affixes_json))
	var stones: Variant = JSON.parse_string(str(row.sockets_json))
	if not rolls is Array or not stones is Array:
		return null
	if not preload("res://source/common/gameplay/items/affixes/affix_roll.gd").valid_stored(rolls): return null
	item.affixes = preload("res://source/common/gameplay/items/affixes/affix_roll.gd").canonical(rolls)
	item.rarity = str(row.get("rarity", legacy_rarity(item.affixes)))
	if not valid_rarity(item.rarity,item.affixes): return null
	item.sockets = stones
	return item

## One-time compatibility classification; never used to change an explicit rarity.
static func legacy_rarity(rolls: Array) -> String:
	if rolls.is_empty(): return "normal"
	var counts: Dictionary={"prefix":0,"suffix":0}
	for r: Variant in rolls:
		if not r is Dictionary or r.get("affix_version",0)!=1: return "rare"
		counts[str(r.get("kind",""))]=int(counts.get(str(r.get("kind","")),0))+1
	return "magic" if rolls.size()<=2 and counts.prefix<=1 and counts.suffix<=1 else "rare"

static func valid_rarity(value: String, rolls: Array) -> bool:
	if value=="normal": return rolls.is_empty()
	if value=="rare": return rolls.size()<=6
	if value!="magic" or rolls.size()>2: return false
	var prefix:=0;var suffix:=0
	for r: Dictionary in rolls:
		if r.get("kind","")=="prefix": prefix+=1
		elif r.get("kind","")=="suffix": suffix+=1
		else: return false
	return prefix<=1 and suffix<=1
