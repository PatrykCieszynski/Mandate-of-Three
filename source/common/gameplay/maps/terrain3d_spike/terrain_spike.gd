class_name Terrain3DSpike
extends Node3D
## Isolated local workflow preview; uses production actors/rig, no new controller.
var terrain
var player: PlayerActor3D
var mob: MobActor3D
var rig: MandateCamera3D
var visual: WorldVisualEnvironment
var water: MeshInstance3D
var animate_preview: bool = true
var mob_path := PackedVector3Array()
var _path_index: int = 0
var _time: float = 0.0
var _local_clock: WorldTime

func _ready() -> void:
	terrain = get_node("Navigation/Terrain")
	# Configure after native subsystem initialization; early aliases can be ignored.
	terrain.collision.mode = 3
	terrain.collision.layer = 17
	terrain.collision.mask = 0
	player = PlayerActor3D.new()
	player.name = "WorkflowPlayer"
	player.setup("Terrain3D preview",Color("b8cda0"))
	player.position = Vector3(52,terrain.data.get_height(Vector3(52,0,55))+0.1,55)
	add_child(player)
	mob = MobActor3D.new()
	mob.name = "NavigationDog"
	mob.definition = preload("res://source/common/gameplay/mobs/wild_dog.tres")
	mob.setup_mob(1,Vector3(72,terrain.data.get_height(Vector3(72,0,72))+0.1,72))
	add_child(mob)
	if DisplayServer.get_name() != "headless" and not GameMode.is_world_server():
		_build_preview()

func _build_preview() -> void:
	rig = MandateCamera3D.new()
	rig.can_control = func() -> bool: return true
	add_child(rig)
	terrain.set_camera(rig.camera)
	visual = preload("res://source/client/world_visuals/world_visual_environment.tscn").instantiate()
	_local_clock = WorldTime.authority(preload("res://source/common/gameplay/world_time/world_time_settings.tres"))
	visual.world_time = _local_clock
	add_child(visual)
	water = MeshInstance3D.new()
	water.name = "V3Water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(58,240)
	plane.subdivide_width = 115
	plane.subdivide_depth = 479
	water.mesh = plane
	water.position = Vector3(227,-0.5,128)
	water.material_override = preload("res://source/client/world_visuals/water/region_water_material.tres").duplicate()
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water.extra_cull_margin = 0.15
	add_child(water)
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var label := Label.new()
	label.position = Vector2(20,20)
	label.text = "V4 Terrain3D · isolated local preview\nWASD — production movement · RMB — orbit · wheel — zoom\nGrass/dirt arena → north: gentle hill / steep rock / hollow\nEast: V3 shoreline · editor: select Navigation/Terrain"
	canvas.add_child(label)

func _physics_process(delta: float) -> void:
	if not animate_preview: return
	var direction := Vector2.ZERO
	if rig != null:
		direction = rig.movement_direction(Input.get_vector("player_move_left","player_move_right","player_move_up","player_move_down"))
	player.simulate(delta,direction)
	if mob_path.is_empty() and NavigationServer3D.map_get_iteration_id(get_world_3d().navigation_map)>0:
		mob_path = NavigationServer3D.map_get_path(get_world_3d().navigation_map,mob.position,Vector3(74,terrain.data.get_height(Vector3(74,0,110)),110),true)
	var toward := Vector2.ZERO
	if _path_index<mob_path.size():
		var offset: Vector3 = mob_path[_path_index]-mob.position
		if Vector2(offset.x,offset.z).length()<0.6: _path_index+=1
		else: toward = Vector2(offset.x,offset.z).normalized()
	mob.simulate_mob(delta,toward,Time.get_ticks_msec())

func _process(delta: float) -> void:
	if rig != null:
		rig.update_camera(delta,player.position,true)
	if water != null:
		_time += delta
		(water.material_override as ShaderMaterial).set_shader_parameter("surface_time",_time)
