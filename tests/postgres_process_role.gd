extends Node
var main: Node
var stopping:=false
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
	if not FileAccess.file_exists(directory+"/stop-"+role): return
	stopping=true
	if role=="world":
		var world: WorldServer=main.get_node("WorldServer")
		assert(await world.shutdown_economy())
		assert(world.database.save_all_connected(world.connected_players)>=0)
		assert(await world.database.shutdown_database())
		assert(world.economy_bootstrap.status().stopped)
	elif role=="master":
		assert(await main.get_node("WorldManagerServer").economy_bootstrap.shutdown_master())
	FileAccess.open(directory+"/stopped-"+role,FileAccess.WRITE).store_string("ok")
	get_tree().quit()
