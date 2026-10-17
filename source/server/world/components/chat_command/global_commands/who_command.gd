extends ChatCommand
## List players currently in the caller's instance. Scoped to the local instance
## because a world-wide /who would dump hundreds of lines into chat; if/when we
## need a global roster, build it as a dedicated panel.


func _init() -> void:
	command_name = "who"
	command_priority = 1 # moderator+
	command_usage = "/who"


func execute(args: PackedStringArray, peer_id: int, server_instance: ServerInstance) -> String:
	var lines: PackedStringArray = PackedStringArray()
	var world: GameWorld3D = server_instance.get_node_or_null("GameWorld") as GameWorld3D
	if world == null:
		return "No active 3D world in this instance."
	for pid: int in server_instance.connected_peers:
		if not world.characters.has(pid):
			continue
		var res: PlayerResource = server_instance.world_server.connected_players.get(pid)
		if res == null:
			continue
		lines.append("- %s @%s (#%d)" % [res.display_name, res.account_name, res.player_id])

	if lines.is_empty():
		return "No players in this instance."

	var instance_name: String = server_instance.instance_resource.instance_name
	return "Players in %s (%d):\n%s" % [instance_name, lines.size(), "\n".join(lines)]
