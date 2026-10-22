extends Node
var main: Node
var stopping:=false
var seeded:=false
var capacity_verified:=false
var directory: String
func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	directory=OS.get_environment("MANDATE_PG_FIXTURE_DIR")
	var role: String=GameMode.mode().trim_suffix("-server")
	main=load("res://source/server/"+role+"/"+role+"_main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
func _process(_delta: float) -> void:
	if main==null or not main.is_inside_tree() or stopping: return
	var role: String=GameMode.mode().trim_suffix("-server")
	if role=="world" and not capacity_verified and FileAccess.file_exists(directory+"/probe-capacity"):
		var world: WorldServer=main.get_node("WorldServer")
		if world.connected_players.size()==1:
			var player: PlayerResource=world.connected_players.values()[0]
			var account: int=world.resolve_account_id(player.player_id)
			assert(world.runtime_settings.value("world_sessions")==1)
			assert(not world.inventory_runtime.has_account_capacity([account,999999]))
			assert(not world.wallet_runtime.has_account_capacity([account,999999]))
			FileAccess.open(directory+"/capacity-proof",FileAccess.WRITE).store_string("configured native owners refuse second account")
			capacity_verified=true
	if role=="world" and not seeded and FileAccess.file_exists(directory+"/seed-maintenance"):
		var world: WorldServer=main.get_node("WorldServer")
		if world.connected_players.size()==1:
			var peer: int=world.connected_players.keys()[0]
			if world.wallet_runtime.add_income(peer,37):
				world.database.award_experience(world.connected_players[peer],41)
				var player: PlayerResource=world.connected_players[peer]
				FileAccess.open(directory+"/maintenance-seeded",FileAccess.WRITE).store_string(JSON.stringify({"level":player.level,"experience":player.experience,"points":player.available_attributes_points}))
				seeded=true
	if role=="world" and FileAccess.file_exists(directory+"/observe-blocked"):
		var world: WorldServer=main.get_node("WorldServer")
		FileAccess.open(directory+"/blocked-wallet-report",FileAccess.WRITE).store_string(JSON.stringify({"state":world.economy_bootstrap.status().state,"workers_stopped":world.economy_bootstrap.status().stopped,"drained":world.wallet_runtime.drained(),"players":world.connected_players.size()}))
	if not FileAccess.file_exists(directory+"/stop-"+role): return
	stopping=true
	if role=="world":
		var world: WorldServer=main.get_node("WorldServer")
		assert(await world.shutdown_economy())
		if main.get_node("WorldManagerClient")._maintenance.is_empty():
			assert(world.database.save_all_connected(world.connected_players)>=0)
			assert(await world.database.shutdown_database())
		assert(world.economy_bootstrap.status().stopped)
	elif role=="master":
		assert(await main.get_node("WorldManagerServer").economy_bootstrap.shutdown_master())
	FileAccess.open(directory+"/stopped-"+role,FileAccess.WRITE).store_string("ok")
	get_tree().quit()
