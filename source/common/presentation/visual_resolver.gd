class_name VisualResolver
extends RefCounted
## Curated logical IDs only. Optional resources are never preloaded.
const MOB_IDS: Array[StringName] = [&"wolf", &"wild_boar", &"bear", &"tiger", &"barbarian_soldier", &"barbarian_infantry", &"barbarian_bow", &"orc_soldier", &"orc_scouter", &"orc_knight", &"orc_black", &"orc_magician", &"metinstone_01", &"metinstone_02"]
const ARMOR_IDS: Array[StringName] = [&"warrior_saja", &"warrior_cheongrin"]
const SWORD_IDS: Array[StringName] = [&"sword_00020", &"sword_00030", &"sword_00040"]
const STRAY_DOG := &"stray_dog"
const FINAL_DOG := "res://assets/final/mobs/stray_dog.tscn"
const DEV_DOG := "res://dev_assets/metin2/mobs/stray_dog/stray_dog.glb"
const PLACEHOLDER_DOG := "res://assets/placeholders/mobs/stray_dog_placeholder.tscn"
const PLACEHOLDER_WARRIOR := "res://assets/placeholders/players/warrior.tscn"
const PLACEHOLDER_SWORD := "res://assets/placeholders/weapons/iron_sword.tscn"

static func local_development_enabled() -> bool:
	return OS.has_feature("editor") and not OS.has_feature("dedicated_server") \
		and not OS.get_cmdline_user_args().has("--no-dev-visuals") \
		and OS.get_environment("MANDATE_NO_DEV_VISUALS") != "1"

static func paths(visual_id: StringName) -> PackedStringArray:
	match visual_id:
		&"warrior_male": return paths(&"warrior")
		&"stray_dog": return [FINAL_DOG, DEV_DOG, PLACEHOLDER_DOG]
		&"warrior": return ["res://assets/final/players/warrior.tscn", "res://dev_assets/metin2/players/warrior/warrior.glb", PLACEHOLDER_WARRIOR]
		&"warrior_armor": return ["res://assets/final/players/warrior_armor.tscn", "res://dev_assets/metin2/players/warrior/warrior_armor.glb", PLACEHOLDER_WARRIOR]
		&"iron_sword": return ["res://assets/final/weapons/iron_sword.tscn", "res://dev_assets/metin2/weapons/iron_sword/iron_sword.glb", PLACEHOLDER_SWORD]
	if MOB_IDS.has(visual_id):
		return ["res://assets/final/mobs/%s.tscn" % visual_id, "res://dev_assets/metin2/mobs/%s/%s.glb" % [visual_id, visual_id], "res://assets/placeholders/mobs/mob_placeholder.tscn"]
	if ARMOR_IDS.has(visual_id):
		return ["res://assets/final/players/%s.tscn" % visual_id, "res://dev_assets/metin2/players/warrior/%s.glb" % visual_id, PLACEHOLDER_WARRIOR]
	if SWORD_IDS.has(visual_id):
		return ["res://assets/final/weapons/%s.tscn" % visual_id, "res://dev_assets/metin2/weapons/%s/%s.glb" % [visual_id, visual_id], PLACEHOLDER_SWORD]
	return []

static func resolve(visual_id: StringName) -> PackedScene:
	var candidates := paths(visual_id)
	if candidates.is_empty(): return null
	var final_path := candidates[0]
	if ResourceLoader.exists(final_path, "PackedScene") and (not OS.has_feature("editor") or FileAccess.file_exists(final_path)):
		var final_scene := load(final_path) as PackedScene
		if final_scene != null: return final_scene
	# Stale import artifacts must not resurrect a deleted local source file.
	var dev_path := candidates[1]
	if local_development_enabled() and FileAccess.file_exists(dev_path) and ResourceLoader.exists(dev_path, "PackedScene"):
		var dev_scene := load(dev_path) as PackedScene
		if dev_scene != null: return dev_scene
	return load(candidates[2]) as PackedScene
