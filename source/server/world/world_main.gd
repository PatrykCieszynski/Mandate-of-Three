class_name WorldMain
extends Node


var world_info: Dictionary


func _ready() -> void:
	# Server tick rate
	# For comparaison:
	# Eve Online - 1 tick par second.
	# Fortnite (Battle royale 100 players) - 30 ticks per second.
	# Albion Online - 2 ticks per second (to verify).
	# Valorant (5v5 FPS game) - 128 ticks per second.
	# I believe it depends of your game and architecture, it's a large topic.
	Engine.set_physics_ticks_per_second(60) # Authoritative CharacterBody3D physics; snapshots remain 20 Hz.
	
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title("World Server")
	else:
		# Headless has no vsync, so _process — which drives the sync manager's
		# 20/10 Hz send accumulators — would spin uncapped and burn a full core.
		# 60 fps keeps the send timing accurate at a fraction of the CPU.
		Engine.max_fps = 60
	
	# Default config path. to use another one, override this;
	# or write --config=config_file_path.cfg as a launch argument.
	world_info = ConfigFileUtils.load_section_with_defaults(
		"world-server",
		CmdlineUtils.get_parsed_args().get("config", "res://data/config/world_config.cfg"),
		{
			"name": "NoName",
			"max_players": 200,
			"hardcore": false,
			"motd": "Welcome!",
			"bonus_xp": 0.0,
			"max_character": 5,
			"pvp": true
		}
		
	)
	await get_tree().create_timer(0.5).timeout
	if world_info.has("error"):
		printerr("World server loading configuration failed.")
	else:
		var settings: Dictionary=preload("res://source/server/world/database/postgres/economy_bootstrap_settings.gd").load_config(CmdlineUtils.get_parsed_args().get("config","res://data/config/world_config.cfg"))
		if not settings.ok:
			push_error("World economy startup refused: "+str(settings.error));return
		if settings.backend=="postgresql":
			var profiles_ready: bool=$Database.start_postgres_profiles(settings) if settings.get("realm_state",false) else $Database.start_profile_database(str(settings.profile_path))
			if not profiles_ready:
				push_error("World economy startup refused: profiles");return
			settings["profile_id"]=$Database.economy_profile_id
			var owner:=preload("res://source/server/world/database/postgres/economy_bootstrap_postgres.gd").new()
			if not await owner.start_world($WorldServer,settings):
				push_error("World economy startup refused: "+owner.error);return
			$Database.wallet_ready=false # Trusted Master manifest is still required.
		else:
			$Database.start_database(world_info)
		$WorldManagerClient.start_client_to_master_server(world_info)
		$WorldServer.start_world_server()
