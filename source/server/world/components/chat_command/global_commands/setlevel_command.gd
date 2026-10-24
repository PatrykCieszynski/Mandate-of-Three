extends ChatCommand
## Privileged forward-only test leveling; uses the same milestone grant path.


func _init() -> void:
	command_name = "setlevel"
	command_priority = 100 # senior_admin
	command_usage = "/setlevel <self|@account|#id> <level>"


func execute(args: PackedStringArray, peer_id: int, server_instance: ServerInstance) -> String:
	if args.size() != 3:
		return "Usage: " + command_usage

	var target: CommandTarget.Result = CommandTarget.resolve(args[1], peer_id, server_instance)
	if not target.ok:
		return target.error
	if not target.online:
		return "%s must be online." % target.label()

	var new_level: int = args[2].to_int()
	if new_level < 1 or new_level > 20:
		return "Level must be between 1 and 20."

	var ws: WorldServer = server_instance.world_server
	var res: PlayerResource = target.resource
	var level_before: int = res.level
	if new_level <= level_before: return "Setlevel only advances levels; rewinding could replay progression rewards."
	var amount: int=-res.experience
	for old_level: int in range(level_before,new_level): amount += PlayerResource.LEVEL_XP_BASE*old_level
	var result: Dictionary=res.add_experience(amount)
	var levels_jumped: int=int(result.levels_gained)
	ws.database.mark_progression_dirty(res)
	ws.refresh_character_stats(target.peer_id)

	ws.data_push.rpc_id(target.peer_id, &"combat.reward", {
		"xp": 0,
		"level": res.level,
		"levels_gained": maxi(0, levels_jumped),
		"points_gained": int(result.points_gained),
		"experience": 0,
		"xp_to_next": res.level_xp_to_next(),
		"loot": [],
	})


	return "Set %s to level %d." % [target.label(), new_level]
