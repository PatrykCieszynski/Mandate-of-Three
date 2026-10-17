extends ChatCommand
## Report which instance/map a player is in, plus their position. Online only.


func _init() -> void:
	command_name = "where"
	command_priority = 1 # moderator+
	command_usage = "/where <self|@account|#id>"


func execute(args: PackedStringArray, peer_id: int, server_instance: ServerInstance) -> String:
	if args.size() != 2:
		return "Usage: " + command_usage

	var target: CommandTarget.Result = CommandTarget.resolve(args[1], peer_id, server_instance)
	if not target.ok:
		return target.error
	if not target.online:
		return "%s is offline." % target.label()

	var ws: WorldServer = server_instance.world_server
	var inst: ServerInstance = ws.instance_manager.find_instance_for_peer(target.peer_id)
	if inst == null:
		return "%s is online but not in any instance." % target.label()
	var world: GameWorld3D = inst.get_node_or_null("GameWorld") as GameWorld3D
	var actor: PlayerActor3D = world.characters.get(target.peer_id) if world != null else null
	if actor == null:
		return "%s is assigned to %s but has not joined the 3D world." % [target.label(), inst.instance_resource.instance_name]
	var pos: Vector3 = actor.global_position
	return "%s is in %s at (%d, %d, %d)." % [
		target.label(), inst.instance_resource.instance_name, int(pos.x), int(pos.y), int(pos.z)
	]
