extends RefCounted
class_name PlayerProfileCodec

## Retired payloads are copied verbatim, without normalization or execution.
const RETIRED_DEFAULTS: Dictionary = {
	"inventory_json": "{}",
	"equipment_json": "{}",
	"skills_json": "{}",
	"mastery_json": "{}",
	"quests_json": "{}",
	"dailies_json": "{}",
	"dungeon_lockouts_json": "{}",
	"redeemed_codes_json": "[]",
	"joined_guild_ids_json": "[]",
	"active_guild_id": 0,
	"led_guild_id": 0,
}


static func decode(row: Dictionary) -> PlayerResource:
	var player: PlayerResource = PlayerResource.new()

	player.player_id = int(row.get("player_id", 0))
	player.account_name = str(row.get("account_name", ""))

	player.display_name = str(row.get("display_name", "Player"))
	player.skin_id = int(row.get("skin_id", 1))

	player.level = int(row.get("level", 1))
	player.experience = int(row.get("experience", 0))

	player.profile_status = str(row.get("profile_status", ""))
	player.profile_animation = str(row.get("profile_animation", ""))

	var attribute_values: Dictionary=JSON.parse_string(str(row.get("attributes_json", "{}")))
	for key: String in attribute_values: player.attributes[StringName(key)]=int(attribute_values[key])
	player.available_attributes_points = int(row.get("available_attributes_points", 0))
	var progression: Variant = JSON.parse_string(str(row.get("progression_json","{}")))
	player.load_progression_state(progression if progression is Dictionary else {})

	var friends_v: Variant = JSON.parse_string(str(row.get("friends_json", "[]")))
	player.friends = PackedInt64Array(friends_v if friends_v is Array else [])

	var blocked_v: Variant = JSON.parse_string(str(row.get("blocked_ids_json", "[]")))
	player.blocked_ids = PackedInt64Array(blocked_v if blocked_v is Array else [])

	var owned_skins_v: Variant = JSON.parse_string(str(row.get("owned_skins_json", "[]")))
	player.owned_skins = PackedInt64Array(owned_skins_v if owned_skins_v is Array else [])
	# The equipped skin is always owned — backfills existing players (pre-wardrobe) and any
	# row whose blob drifted, so the wardrobe never shows your current look as locked.
	if not player.owned_skins.has(player.skin_id):
		player.owned_skins.append(player.skin_id)

	var wardstones_v: Variant = JSON.parse_string(str(row.get("wardstones_json", "[]")))
	player.wardstones = PackedStringArray(wardstones_v if wardstones_v is Array else [])

	player.server_roles = JSON.parse_string(str(row.get("server_roles_json", "{}"))) as Dictionary

	var lb_stats_v: Variant = JSON.parse_string(str(row.get("stats_json", "{}")))
	player.lb_stats = lb_stats_v if lb_stats_v is Dictionary else {}

	var titles_v: Variant = JSON.parse_string(str(row.get("titles_json", "{}")))
	if titles_v is Dictionary:
		var unlocked_v: Variant = (titles_v as Dictionary).get("unlocked", [])
		player.titles_unlocked = PackedStringArray(unlocked_v if unlocked_v is Array else [])
		player.display_title = str((titles_v as Dictionary).get("display", ""))
		var trophies_v: Variant = (titles_v as Dictionary).get("trophies", [])
		player.displayed_trophies = PackedStringArray(trophies_v if trophies_v is Array else [])

	for column: String in RETIRED_DEFAULTS:
		player.retired_profile_fields[column] = row.get(column, RETIRED_DEFAULTS[column])
	return player

## Decimal counters avoid JSON double rounding above 2^53. Old numeric JSON remains readable.
static func encode_attributes(attributes: Dictionary) -> String:
	var values: Dictionary={}
	for key: Variant in attributes: values[str(key)]=str(int(attributes[key]))
	return JSON.stringify(values)
static func encode_progression(progression: Dictionary) -> String:
	var values:=progression.duplicate()
	for key: String in ["skill_points","revision"]: values[key]=str(int(progression.get(key,0)))
	return JSON.stringify(values)
