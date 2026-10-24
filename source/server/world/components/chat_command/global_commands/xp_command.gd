extends ChatCommand
## Privileged XP grant through current PlayerResource progression.


func _init() -> void:
	command_name = "xp"
	command_priority = 100 # senior_admin
	command_usage = "/xp <self|@account|#id> <amount>"


func execute(args: PackedStringArray, peer_id: int, server_instance: ServerInstance) -> String:
	if args.size() != 3:
		return "Usage: " + command_usage

	var target: CommandTarget.Result = CommandTarget.resolve(args[1], peer_id, server_instance)
	if not target.ok:
		return target.error
	if not target.online:
		return "%s must be online to grant XP." % target.label()

	if not args[2].is_valid_int() or args[2].to_int() <= 0:
		return "Invalid XP amount."
	var amount: int = args[2].to_int()
	var ws: WorldServer = server_instance.world_server
	var res: PlayerResource = target.resource
	# Use the active World3D path: dirty checkpoint state and owner XP notification.
	ws.database.award_experience(res, amount)


	return "Granted %d XP to %s (now level %d, %d/%d)." % [
		amount, target.label(), res.level, res.experience, res.level_xp_to_next()
	]
