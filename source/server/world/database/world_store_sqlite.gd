class_name WorldStoreSqlite
extends RefCounted


const STARTING_YANG: int = 1500

var economic_initialization: bool=true # Profile-only PG bootstrap disables legacy starter currency.
var db: SqliteSoci


func _init(_db: SqliteSoci) -> void:
	db = _db


func begin() -> bool:
	return db.query("BEGIN;")


func commit() -> bool:
	return db.query("COMMIT;")


func rollback() -> bool:
	return db.query("ROLLBACK;")


## Bind legacy world names only from a verified Master handoff. Never invent IDs.
func bind_account_identity(account_name: String, account_id: int, create_verified: bool = false) -> bool:
	if account_name.is_empty() or account_id <= 0 or not db.query("BEGIN IMMEDIATE;"): return false
	if create_verified and not db.query_with_bindings("INSERT OR IGNORE INTO accounts(account_name) VALUES(?);",[account_name]):
		db.query("ROLLBACK;")
		return false
	var ok := db.query_with_bindings("SELECT master_account_id FROM accounts WHERE account_name=?;",[account_name]) and db.query_result.size()==1
	if ok:
		var current: Variant = db.query_result[0].master_account_id
		ok = current == null or int(current) == account_id
	if ok:
		ok = db.query_with_bindings("SELECT account_name FROM accounts WHERE master_account_id=? AND account_name<>?;",[account_id,account_name]) and db.query_result.is_empty()
	if ok:
		ok = db.query_with_bindings("UPDATE accounts SET master_account_id=? WHERE account_name=?;",[account_id,account_name])
	if ok and db.query("COMMIT;"): return true
	db.query("ROLLBACK;")
	return false

func resolve_account_id(character_id: int) -> int:
	if not db.query_with_bindings("SELECT a.master_account_id FROM accounts a JOIN players p ON p.account_name=a.account_name WHERE p.player_id=?;",[character_id]) or db.query_result.is_empty(): return 0
	return int(db.query_result[0].master_account_id) if db.query_result[0].master_account_id != null else 0

## Read-only diagnostics; legacy accounts stay unbound until a verified login.
func unbound_accounts() -> Array:
	if not db.query("SELECT account_name FROM accounts WHERE master_account_id IS NULL ORDER BY account_name;"): return []
	return db.query_result.duplicate(true)

## Explicit server-side Master manifest, never a client payload. Reports only; no repair.
func audit_account_identities(master_ids: Dictionary) -> Dictionary:
	var report := {"ok":false,"unbound":[],"orphaned":[],"mismatched":[]}
	if not db.query("SELECT account_name,master_account_id FROM accounts ORDER BY account_name;"): return report
	for row: Dictionary in db.query_result:
		if not master_ids.has(row.account_name): report.orphaned.append(row.account_name)
		elif row.master_account_id == null: report.unbound.append(row.account_name)
		elif int(row.master_account_id) != int(master_ids[row.account_name]): report.mismatched.append(row.account_name)
	if not db.query("SELECT DISTINCT p.account_name FROM players p LEFT JOIN accounts a ON a.account_name=p.account_name WHERE a.account_name IS NULL;"): return report
	for row: Dictionary in db.query_result:
		if not report.orphaned.has(row.account_name): report.orphaned.append(row.account_name)
	report.ok = true
	return report

func get_player(player_id: int) -> PlayerResource:
	db.query_with_bindings("SELECT * FROM players WHERE player_id=?;", [player_id])
	if db.query_result.is_empty():
		return null

	var row: Dictionary = db.query_result[0]
	return _row_to_player(row)


func save_progression(players: Array[PlayerResource]) -> bool:
	if players.is_empty(): return true
	if not db.query("BEGIN IMMEDIATE;"): return false
	for player: PlayerResource in players:
		if not db.query_with_bindings("UPDATE players SET level=?,experience=?,available_attributes_points=?,attributes_json=?,progression_json=? WHERE player_id=?;",
			[player.level,player.experience,player.available_attributes_points,PlayerProfileCodec.encode_attributes(player.attributes),PlayerProfileCodec.encode_progression(player.progression_state()),player.player_id]) \
			or not db.query("SELECT changes() AS n;") or int(db.query_result[0].n) != 1:
			db.query("ROLLBACK;")
			return false
	if not db.query("COMMIT;"):
		db.query("ROLLBACK;")
		return false
	return true


func save_player(player: PlayerResource) -> bool:
	var attributes_json: String = PlayerProfileCodec.encode_attributes(player.attributes)
	var inventory_json: String = str(player.retired_profile_fields.get("inventory_json", "{}"))
	var equipment_json: String = str(player.retired_profile_fields.get("equipment_json", "{}"))
	var skills_json: String = str(player.retired_profile_fields.get("skills_json", "{}"))
	var mastery_json: String = str(player.retired_profile_fields.get("mastery_json", "{}"))
	var quests_json: String = str(player.retired_profile_fields.get("quests_json", "{}"))

	var friends_json: String = JSON.stringify(player.friends)
	var blocked_ids_json: String = JSON.stringify(player.blocked_ids)
	var owned_skins_json: String = JSON.stringify(player.owned_skins)
	var server_roles_json: String = JSON.stringify(player.server_roles)
	var stats_json: String = JSON.stringify(player.lb_stats)
	var titles_json: String = JSON.stringify({
		"unlocked": player.titles_unlocked,
		"display": player.display_title,
		"trophies": player.displayed_trophies,
	})
	var dailies_json: String = str(player.retired_profile_fields.get("dailies_json", "{}"))
	var dungeon_lockouts_json: String = str(player.retired_profile_fields.get("dungeon_lockouts_json", "{}"))
	var redeemed_codes_json: String = str(player.retired_profile_fields.get("redeemed_codes_json", "[]"))
	var wardstones_json: String = JSON.stringify(player.wardstones)

	var joined_guild_ids_json: String = str(player.retired_profile_fields.get("joined_guild_ids_json", "[]"))

	return db.query_with_bindings(
		"INSERT OR REPLACE INTO players("
		+ "player_id, account_name, display_name, skin_id, level, experience, available_attributes_points, "
		+ "profile_status, profile_animation, "
		+ "attributes_json, inventory_json, equipment_json, skills_json, mastery_json, quests_json, friends_json, blocked_ids_json, owned_skins_json, server_roles_json, stats_json, titles_json, dailies_json, dungeon_lockouts_json, redeemed_codes_json, wardstones_json, "
		+ "active_guild_id, joined_guild_ids_json, led_guild_id, progression_json"
		+ ") VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
		[
			player.player_id,
			player.account_name,
			player.display_name,
			player.skin_id,
			player.level,
			player.experience,
			player.available_attributes_points,

			player.profile_status,
			player.profile_animation,

			attributes_json,
			inventory_json,
			equipment_json,
			skills_json,
			mastery_json,
			quests_json,
			friends_json,
			blocked_ids_json,
			owned_skins_json,
			server_roles_json,
			stats_json,
			titles_json,
			dailies_json,
			dungeon_lockouts_json,
			redeemed_codes_json,
			wardstones_json,

			int(player.retired_profile_fields.get("active_guild_id", 0)),
			joined_guild_ids_json,
			int(player.retired_profile_fields.get("led_guild_id", 0)),
			PlayerProfileCodec.encode_progression(player.progression_state())
		]
	)


func create_player_character(account_name: String, character_data: Dictionary) -> int:
	db.query_with_bindings("INSERT OR IGNORE INTO accounts(account_name) VALUES(?);", [account_name])

	db.query("SELECT COALESCE(MAX(player_id), 0) AS max_id FROM players;")
	var max_id: int = int(db.query_result[0].get("max_id", 0))
	var next_id: int = max_id + 1

	var player: PlayerResource = PlayerResource.new()
	player.init(
		next_id,
		account_name,
		str(character_data.get("name", "Player")),
		int(character_data.get("skin", 1))
	)
	# The chosen creation skin is owned from the start, so it's equippable in the wardrobe.
	player.owned_skins = PackedInt64Array([player.skin_id])

	# Stats V1 points are earned at EXP milestones.
	player.available_attributes_points = 0
	# Everyone who plays the alpha carries the badge for it.
	player.titles_unlocked = PackedStringArray(["Alpha tester"])
	player.display_title = "Alpha tester"
	# Leave defaults to PlayerResource where possible.
	if not db.query("BEGIN IMMEDIATE;"): return -1
	if not save_player(player):
		db.query("ROLLBACK;");return -1
	if economic_initialization and not db.query_with_bindings("INSERT OR IGNORE INTO account_wallets(account_id,yang) SELECT master_account_id,? FROM accounts WHERE account_name=? AND master_account_id IS NOT NULL;", [STARTING_YANG, account_name]):
		db.query("ROLLBACK;")
		return -1
	if not db.query_with_bindings("SELECT master_account_id FROM accounts WHERE account_name=? AND master_account_id IS NOT NULL;",[account_name]) or db.query_result.is_empty():
		db.query("ROLLBACK;")
		return -1
	if not db.query("COMMIT;"):
		db.query("ROLLBACK;")
		return -1
	return next_id


func get_account_characters(account_name: String) -> Dictionary:
	db.query_with_bindings(
		"SELECT player_id, display_name, skin_id, level FROM players WHERE account_name=?;",
		[account_name]
	)

	var out: Dictionary = {}
	for row: Dictionary in db.query_result:
		var pid: int = int(row.get("player_id", 0))
		out[pid] = {
			"name": str(row.get("display_name", "")),
			"skin": int(row.get("skin_id", 1)),
			"class": "???",
			"level": int(row.get("level", 1))
		}

	return out


## Every player holding a non-empty persisted role, for the /staff roster + role
## audits. Returns [{player_id, name, account, roles}] with roles parsed to a Dict.
func get_role_holders() -> Array:
	db.query(
		"SELECT player_id, display_name, account_name, server_roles_json FROM players "
		+ "WHERE server_roles_json IS NOT NULL AND server_roles_json NOT IN ('{}', '');"
	)
	var out: Array = []
	for row: Dictionary in db.query_result:
		var roles_v: Variant = JSON.parse_string(str(row.get("server_roles_json", "{}")))
		out.append({
			"player_id": int(row.get("player_id", 0)),
			"name": str(row.get("display_name", "")),
			"account": str(row.get("account_name", "")),
			"roles": roles_v if roles_v is Dictionary else {},
		})
	return out


func get_player_profile_row(player_id: int) -> Dictionary:
	db.query_with_bindings(
		"SELECT player_id, account_name, display_name, skin_id, level, inventory_json, profile_status, profile_animation, active_guild_id, titles_json, stats_json "
		+ "FROM players WHERE player_id=?;",
		[player_id]
	)

	if db.query_result.is_empty():
		return {}

	# Flatten the title display field for the profile handler so it doesn't have
	# to parse JSON. Other fields stay in their raw form.
	var row: Dictionary = db.query_result[0]
	var titles_v: Variant = JSON.parse_string(str(row.get("titles_json", "{}")))
	if titles_v is Dictionary:
		row["display_title"] = str((titles_v as Dictionary).get("display", ""))
	return row


func _row_to_player(row: Dictionary) -> PlayerResource:
	return PlayerProfileCodec.decode(row)

func get_player_display_name(player_id: int) -> String:
	db.query_with_bindings(
		"SELECT display_name FROM players WHERE player_id=?;",
		[player_id]
	)

	if db.query_result.is_empty():
		return ""

	return str(db.query_result[0].get("display_name", ""))


## The stable account handle for a character id (works offline). Used to map a
## player_id back to an account for account-level mute/jail.
func get_player_account_name(player_id: int) -> String:
	db.query_with_bindings(
		"SELECT account_name FROM players WHERE player_id=?;",
		[player_id]
	)

	if db.query_result.is_empty():
		return ""

	return str(db.query_result[0].get("account_name", ""))


func search_players(query: String, limit: int, by_account: bool) -> Array:
	var q: String = query.strip_edges()
	if q.is_empty():
		return []

	var like: String = "%" + q + "%"
	var column: String = "account_name" if by_account else "display_name"

	db.query_with_bindings(
		"SELECT player_id, account_name, display_name "
		+ "FROM players "
		+ "WHERE " + column + " LIKE ? COLLATE NOCASE "
		+ "ORDER BY " + column + " ASC "
		+ "LIMIT ?;",
		[like, limit]
	)

	return db.query_result


func spend_attribute(player: PlayerResource, command_id: String, attribute: StringName) -> Dictionary:
	if command_id.is_empty() or command_id.length()>80 or not AttributeMap.KEYS.has(attribute): return {"ok":false,"error":"payload"}
	if not begin(): return {"ok":false,"error":"storage"}
	if not db.query_with_bindings("SELECT attribute FROM stats_commands WHERE character_id=? AND command_id=?;",[player.player_id,command_id]):
		rollback();return {"ok":false,"error":"storage"}
	if not db.query_result.is_empty():
		var matches: bool=str(db.query_result[0].attribute)==str(attribute)
		rollback();return {"ok":true,"replay":true} if matches else {"ok":false,"error":"command_conflict"}
	if player.available_attributes_points<=0:
		rollback();return {"ok":false,"error":"points"}
	if not db.query_with_bindings("SELECT progression_json FROM players WHERE player_id=?;",[player.player_id]) or db.query_result.size()!=1:
		rollback();return {"ok":false,"error":"storage"}
	var persisted: Dictionary=JSON.parse_string(str(db.query_result[0].progression_json))
	if int(persisted.get("revision",0))!=player.stats_revision:
		rollback();return {"ok":false,"error":"stale"}
	var attributes: Dictionary=player.attributes.duplicate()
	attributes[attribute]=int(attributes.get(attribute,0))+1
	var progression: Dictionary=player.progression_state()
	progression.revision=player.stats_revision+1
	if not db.query_with_bindings("UPDATE players SET level=?,experience=?,available_attributes_points=?,attributes_json=?,progression_json=? WHERE player_id=?;",[player.level,player.experience,player.available_attributes_points-1,PlayerProfileCodec.encode_attributes(attributes),PlayerProfileCodec.encode_progression(progression),player.player_id]):
		rollback();return {"ok":false,"error":"storage"}
	if not db.query_with_bindings("INSERT INTO stats_commands(character_id,command_id,attribute) VALUES(?,?,?);",[player.player_id,command_id,str(attribute)]):
		rollback();return {"ok":false,"error":"storage"}
	if not commit():
		db.close_db();return {"ok":false,"error":"outcome_unknown"}
	return {"ok":true,"attributes":attributes,"points":player.available_attributes_points-1,"revision":progression.revision}
