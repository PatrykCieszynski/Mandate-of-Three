extends RefCounted
class_name PlayerProfileCodec

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

	player.attributes.assign(JSON.parse_string(str(row.get("attributes_json", "{}"))) as Dictionary)
	player.inventory = Inventory.normalize(JSON.parse_string(str(row.get("inventory_json", "{}"))) as Dictionary)
	# Equipment: { slot_key (StringName) -> item_id (int) }; JSON gives string keys/float values.
	var equipment_raw: Dictionary = JSON.parse_string(str(row.get("equipment_json", "{}"))) as Dictionary
	player.equipment = {}
	for slot_key in equipment_raw:
		player.equipment[StringName(slot_key)] = int(equipment_raw[slot_key])
	player.available_attributes_points = int(row.get("available_attributes_points", 0))

	# Skills: { skill_name (StringName) -> {"level": int, "xp": int} }; JSON gives string
	# keys and float numbers, so normalize back to StringName keys / int values.
	var skills_raw: Dictionary = JSON.parse_string(str(row.get("skills_json", "{}"))) as Dictionary
	player.skills = {}
	for skill_name in skills_raw:
		var entry: Dictionary = skills_raw[skill_name]
		# Chosen perks: { perk_id (StringName) -> ranks (int) }.
		var perks_raw: Dictionary = entry.get("perks", {}) as Dictionary
		var perks: Dictionary = {}
		for perk_id in perks_raw:
			perks[StringName(perk_id)] = int(perks_raw[perk_id])
		player.skills[StringName(skill_name)] = {
			"level": int(entry.get("level", 1)),
			"xp": int(entry.get("xp", 0)),
			"perks": perks,
		}

	# Outfitting merge (2026-07-02): tailoring + leatherworking became ONE job.
	# Old saves carry the retired keys — fold them into outfitting (keep the
	# higher-level entry so no progress is lost), then drop the retired keys.
	for old_key: StringName in [&"tailoring", &"leatherworking"]:
		if not player.skills.has(old_key):
			continue
		var old_entry: Dictionary = player.skills[old_key]
		var current: Dictionary = player.skills.get(&"outfitting", {"level": 0, "xp": 0, "perks": {}})
		if int(old_entry.get("level", 1)) > int(current.get("level", 0)):
			player.skills[&"outfitting"] = old_entry
		player.skills.erase(old_key)

	# Weapon mastery: {"masteries": {category -> {"level","xp","spent"}},
	# "loadout": {category -> node_id}}. JSON gives string keys / float values —
	# normalize like skills above (categories back to StringName, spent ids stay
	# String — that's how the runtime reads them).
	var mastery_v: Variant = JSON.parse_string(str(row.get("mastery_json", "{}")))
	player.masteries = {}
	player.ability_loadout = {}
	if mastery_v is Dictionary:
		var masteries_raw: Dictionary = (mastery_v as Dictionary).get("masteries", {})
		for category in masteries_raw:
			var m_entry: Dictionary = masteries_raw[category]
			var spent_raw: Dictionary = m_entry.get("spent", {})
			var spent: Dictionary = {}
			for node_id in spent_raw:
				spent[String(node_id)] = true
			player.masteries[StringName(category)] = {
				"level": int(m_entry.get("level", 1)),
				"xp": int(m_entry.get("xp", 0)),
				"spent": spent,
			}
		var loadout_raw: Dictionary = (mastery_v as Dictionary).get("loadout", {})
		for category in loadout_raw:
			# Array of node ids in slot order. Early saves stored a single
			# string — wrap it so alpha characters keep their pick.
			var picks_v: Variant = loadout_raw[category]
			var picks: Array = []
			if picks_v is Array:
				for pick in picks_v:
					picks.append(str(pick))
			elif not str(picks_v).is_empty():
				picks.append(str(picks_v))
			player.ability_loadout[String(category)] = picks

	# Quests: { quest_id (int) -> {"state": StringName, "progress": {obj_index(int) -> count(int)}} }.
	var quests_raw: Dictionary = JSON.parse_string(str(row.get("quests_json", "{}"))) as Dictionary
	player.quests = {}
	for quest_id in quests_raw:
		var quest_entry: Dictionary = quests_raw[quest_id]
		var progress_raw: Dictionary = quest_entry.get("progress", {}) as Dictionary
		var progress: Dictionary = {}
		for obj_index in progress_raw:
			progress[int(obj_index)] = int(progress_raw[obj_index])
		player.quests[int(quest_id)] = {
			"state": StringName(str(quest_entry.get("state", "active"))),
			"progress": progress,
		}

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

	var redeemed_codes_v: Variant = JSON.parse_string(str(row.get("redeemed_codes_json", "[]")))
	player.redeemed_codes = PackedStringArray(redeemed_codes_v if redeemed_codes_v is Array else [])

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

	var dailies_v: Variant = JSON.parse_string(str(row.get("dailies_json", "{}")))
	if dailies_v is Dictionary:
		var quests_v: Variant = (dailies_v as Dictionary).get("quests", [])
		player.daily_quests = quests_v if quests_v is Array else []
		player.dailies_refresh_at_ms = int((dailies_v as Dictionary).get("refresh_at_ms", 0))

	var lockouts_v: Variant = JSON.parse_string(str(row.get("dungeon_lockouts_json", "{}")))
	player.dungeon_lockouts = lockouts_v if lockouts_v is Dictionary else {}

	player.active_guild_id = int(row.get("active_guild_id", 0))

	var joined_v: Variant = JSON.parse_string(str(row.get("joined_guild_ids_json", "[]")))
	player.joined_guild_ids = PackedInt64Array(joined_v if joined_v is Array else [])

	player.led_guild_id = int(row.get("led_guild_id", 0))

	return player
