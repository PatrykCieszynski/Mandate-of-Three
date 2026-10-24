class_name WorldStorePostgres
extends RefCounted


const STARTING_YANG: int = 1500

var economic_initialization: bool=false # Economy is owned by the existing PG domain stores.
var _rows: Array=[]
var db: Object
var last_write_error: String="storage"
var _transaction_failed:=false


func _init(_db: Object) -> void:
	db = _db


func begin() -> bool:
	if last_write_error=="outcome_unknown" or db.in_transaction(): return false
	_transaction_failed=false
	last_write_error="storage"
	return db.begin()


func commit() -> bool:
	if _transaction_failed:
		rollback()
		return false
	if db.commit(): return true
	# A failed COMMIT is not proof of rollback. Do not reopen/replay this session.
	last_write_error="outcome_unknown"
	db.close()
	return false


func rollback() -> bool:
	var ok: bool=db.rollback()
	_transaction_failed=false
	if not ok: db.close()
	return ok


## Bind legacy world names only from a verified Master handoff. Never invent IDs.
func bind_account_identity(account_name: String, account_id: int, _create_verified: bool = false) -> bool:
	return _query("SELECT master_account_id FROM accounts WHERE account_name=:p0 AND master_account_id=:p1;",[account_name,account_id]) and _rows.size()==1

func resolve_account_id(character_id: int) -> int:
	if not _query("SELECT a.master_account_id FROM accounts a JOIN players p ON p.account_name=a.account_name WHERE p.player_id=:p0;",[character_id]) or _rows.is_empty(): return 0
	return int(_rows[0].master_account_id) if _rows[0].master_account_id != null else 0

## Read-only diagnostics; legacy accounts stay unbound until a verified login.
func unbound_accounts() -> Array:
	if not _query("SELECT account_name FROM accounts WHERE master_account_id IS NULL ORDER BY account_name;"): return []
	return _rows.duplicate(true)

## Explicit server-side Master manifest, never a client payload. Reports only; no repair.
func audit_account_identities(master_ids: Dictionary) -> Dictionary:
	var report := {"ok":false,"unbound":[],"orphaned":[],"mismatched":[]}
	if not _query("SELECT account_name,master_account_id FROM accounts ORDER BY account_name;"): return report
	for row: Dictionary in _rows:
		if not master_ids.has(row.account_name): report.orphaned.append(row.account_name)
		elif row.master_account_id == null: report.unbound.append(row.account_name)
		elif int(row.master_account_id) != int(master_ids[row.account_name]): report.mismatched.append(row.account_name)
	if not _query("SELECT DISTINCT p.account_name FROM players p LEFT JOIN accounts a ON a.account_name=p.account_name WHERE a.account_name IS NULL;"): return report
	for row: Dictionary in _rows:
		if not report.orphaned.has(row.account_name): report.orphaned.append(row.account_name)
	report.ok = true
	return report

func get_player(player_id: int) -> PlayerResource:
	_query("SELECT * FROM players WHERE player_id=:p0;", [player_id])
	if _rows.is_empty():
		return null

	var row: Dictionary = _rows[0]
	return _row_to_player(row)


func save_progression(players: Array[PlayerResource]) -> bool:
	if players.is_empty(): return true
	if not begin(): return false
	for player: PlayerResource in players:
		if not _query("UPDATE players SET level=:p0,experience=:p1,available_attributes_points=:p2,attributes_json=:p4,progression_json=:p5 WHERE player_id=:p3 RETURNING player_id;",
			[player.level,player.experience,player.available_attributes_points,player.player_id,PlayerProfileCodec.encode_attributes(player.attributes),PlayerProfileCodec.encode_progression(player.progression_state())]) \
			or _rows.size() != 1:
			rollback()
			return false
	if not commit():
		db.close()
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

	var saved: bool=_query(
		"INSERT INTO players("
		+ "player_id, account_name, display_name, skin_id, level, experience, available_attributes_points, "
		+ "profile_status, profile_animation, "
		+ "attributes_json, inventory_json, equipment_json, skills_json, mastery_json, quests_json, friends_json, blocked_ids_json, owned_skins_json, server_roles_json, stats_json, titles_json, dailies_json, dungeon_lockouts_json, redeemed_codes_json, wardstones_json, "
		+ "active_guild_id, joined_guild_ids_json, led_guild_id, progression_json"
		+ ") VALUES(:p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8, :p9, :p10, :p11, :p12, :p13, :p14, :p15, :p16, :p17, :p18, :p19, :p20, :p21, :p22, :p23, :p24, :p25, :p26, :p27, :p28) ON CONFLICT(player_id) DO UPDATE SET display_name=EXCLUDED.display_name, skin_id=EXCLUDED.skin_id, level=EXCLUDED.level, experience=EXCLUDED.experience, available_attributes_points=EXCLUDED.available_attributes_points, profile_status=EXCLUDED.profile_status, profile_animation=EXCLUDED.profile_animation, attributes_json=EXCLUDED.attributes_json, inventory_json=EXCLUDED.inventory_json, equipment_json=EXCLUDED.equipment_json, skills_json=EXCLUDED.skills_json, mastery_json=EXCLUDED.mastery_json, quests_json=EXCLUDED.quests_json, friends_json=EXCLUDED.friends_json, blocked_ids_json=EXCLUDED.blocked_ids_json, owned_skins_json=EXCLUDED.owned_skins_json, server_roles_json=EXCLUDED.server_roles_json, stats_json=EXCLUDED.stats_json, titles_json=EXCLUDED.titles_json, dailies_json=EXCLUDED.dailies_json, dungeon_lockouts_json=EXCLUDED.dungeon_lockouts_json, redeemed_codes_json=EXCLUDED.redeemed_codes_json, wardstones_json=EXCLUDED.wardstones_json, active_guild_id=EXCLUDED.active_guild_id, joined_guild_ids_json=EXCLUDED.joined_guild_ids_json, led_guild_id=EXCLUDED.led_guild_id, progression_json=EXCLUDED.progression_json WHERE players.account_name=EXCLUDED.account_name RETURNING player_id;",
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
	) and _rows.size()==1
	if not saved and db.in_transaction(): _transaction_failed=true
	return saved


func create_player_character(account_name: String, character_data: Dictionary) -> int:
	if not _query("SELECT nextval('realm.player_ids') AS id;"): return -1
	var next_id: int=int(_rows[0].id)

	var player: PlayerResource = PlayerResource.new()
	player.init(
		next_id,
		account_name,
		str(character_data.get("name", "Player")),
		int(character_data.get("skin", 1))
	)
	# The chosen creation skin is owned from the start, so it's equippable in the wardrobe.
	player.owned_skins = PackedInt64Array([player.skin_id])

	# ItemInstance/wallet initialization belongs to the existing PG domain owners.
	# Stats V1 points are earned at EXP milestones.
	player.available_attributes_points = 0
	# Everyone who plays the alpha carries the badge for it.
	player.titles_unlocked = PackedStringArray(["Alpha tester"])
	player.display_title = "Alpha tester"
	# Leave defaults to PlayerResource where possible.
	if not begin(): return -1
	if not save_player(player):
		rollback();return -1
	if not _query("SELECT master_account_id FROM accounts WHERE account_name=:p0 AND master_account_id IS NOT NULL;",[account_name]) or _rows.is_empty():
		rollback()
		return -1
	if not commit():
		db.close()
		return -1
	return next_id


func get_account_characters(account_name: String) -> Dictionary:
	_query(
		"SELECT player_id, display_name, skin_id, level FROM players WHERE account_name=:p0;",
		[account_name]
	)

	var out: Dictionary = {}
	for row: Dictionary in _rows:
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
	_query(
		"SELECT player_id, display_name, account_name, server_roles_json FROM players "
		+ "WHERE server_roles_json IS NOT NULL AND server_roles_json NOT IN ('{}', '');"
	)
	var out: Array = []
	for row: Dictionary in _rows:
		var roles_v: Variant = JSON.parse_string(str(row.get("server_roles_json", "{}")))
		out.append({
			"player_id": int(row.get("player_id", 0)),
			"name": str(row.get("display_name", "")),
			"account": str(row.get("account_name", "")),
			"roles": roles_v if roles_v is Dictionary else {},
		})
	return out


func get_player_profile_row(player_id: int) -> Dictionary:
	_query(
		"SELECT player_id, account_name, display_name, skin_id, level, inventory_json, profile_status, profile_animation, active_guild_id, titles_json, stats_json "
		+ "FROM players WHERE player_id=:p0;",
		[player_id]
	)

	if _rows.is_empty():
		return {}

	# Flatten the title display field for the profile handler so it doesn't have
	# to parse JSON. Other fields stay in their raw form.
	var row: Dictionary = _rows[0]
	var titles_v: Variant = JSON.parse_string(str(row.get("titles_json", "{}")))
	if titles_v is Dictionary:
		row["display_title"] = str((titles_v as Dictionary).get("display", ""))
	return row


func _row_to_player(row: Dictionary) -> PlayerResource:
	return PlayerProfileCodec.decode(row)

func get_player_display_name(player_id: int) -> String:
	_query(
		"SELECT display_name FROM players WHERE player_id=:p0;",
		[player_id]
	)

	if _rows.is_empty():
		return ""

	return str(_rows[0].get("display_name", ""))


## The stable account handle for a character id (works offline). Used to map a
## player_id back to an account for account-level mute/jail.
func get_player_account_name(player_id: int) -> String:
	_query(
		"SELECT account_name FROM players WHERE player_id=:p0;",
		[player_id]
	)

	if _rows.is_empty():
		return ""

	return str(_rows[0].get("account_name", ""))


func search_players(query: String, limit: int, by_account: bool) -> Array:
	var q: String = query.strip_edges()
	if q.is_empty():
		return []

	var like: String = "%" + q + "%"
	var column: String = "account_name" if by_account else "display_name"

	_query(
		"SELECT player_id, account_name, display_name "
		+ "FROM players "
		+ "WHERE " + column + " ILIKE :p0 "
		+ "ORDER BY " + column + " ASC "
		+ "LIMIT :p1;",
		[like, limit]
	)

	return _rows


func _query(sql: String, values: Array=[]) -> bool:
	if _transaction_failed:
		_rows=[];return false
	var bindings: Dictionary={}
	for index: int in values.size(): bindings["p"+str(index)]=values[index]
	var returns_rows: bool=sql.begins_with("SELECT ") or sql.contains(" RETURNING ")
	var result: Dictionary=db.query(sql,bindings,100000) if returns_rows else db.execute(sql,bindings)
	_rows=result.get("rows",[]) if result.ok else []
	var ok: bool=result.ok and not result.get("truncated",false)
	if not ok and db.in_transaction(): _transaction_failed=true
	return ok


## Flush pending soft progression and spend exactly one point in one transaction.
## COMMIT uncertainty never mutates RAM or blindly repeats the write.
func spend_attribute(player: PlayerResource, command_id: String, attribute: StringName) -> Dictionary:
	if command_id.is_empty() or command_id.length()>80 or not AttributeMap.KEYS.has(attribute): return {"ok":false,"error":"payload"}
	if not begin(): return {"ok":false,"error":"storage"}
	if not _query("SELECT player_id FROM players WHERE player_id=:p0 FOR UPDATE;",[player.player_id]) or _rows.size()!=1:
		rollback();return {"ok":false,"error":"storage"}
	if not _query("SELECT attribute FROM stats_commands WHERE character_id=:p0 AND command_id=:p1;",[player.player_id,command_id]):
		rollback();return {"ok":false,"error":"storage"}
	if not _rows.is_empty():
		var matches: bool=str(_rows[0].attribute)==str(attribute)
		rollback();return {"ok":true,"replay":true} if matches else {"ok":false,"error":"command_conflict"}
	if player.available_attributes_points<=0:
		rollback();return {"ok":false,"error":"points"}
	if not _query("SELECT progression_json FROM players WHERE player_id=:p0;",[player.player_id]) or _rows.size()!=1:
		rollback();return {"ok":false,"error":"storage"}
	var persisted: Dictionary=JSON.parse_string(str(_rows[0].progression_json))
	if int(persisted.get("revision",0))!=player.stats_revision:
		rollback();return {"ok":false,"error":"stale"}
	var attributes: Dictionary=player.attributes.duplicate()
	attributes[attribute]=int(attributes.get(attribute,0))+1
	var progression: Dictionary=player.progression_state()
	progression.revision=player.stats_revision+1
	if not _query("UPDATE players SET level=:p0,experience=:p1,available_attributes_points=:p2,attributes_json=:p3,progression_json=:p4 WHERE player_id=:p5;",[player.level,player.experience,player.available_attributes_points-1,PlayerProfileCodec.encode_attributes(attributes),PlayerProfileCodec.encode_progression(progression),player.player_id]):
		rollback();return {"ok":false,"error":"storage"}
	if not _query("INSERT INTO stats_commands(character_id,command_id,attribute) VALUES(:p0,:p1,:p2);",[player.player_id,command_id,str(attribute)]):
		rollback();return {"ok":false,"error":"storage"}
	if not commit():
		return {"ok":false,"error":"outcome_unknown"}
	return {"ok":true,"attributes":attributes,"points":player.available_attributes_points-1,"revision":progression.revision}
