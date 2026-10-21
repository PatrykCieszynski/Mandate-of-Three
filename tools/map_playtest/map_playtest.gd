extends Marker3D
## Editor-only local walking harness. Never instantiated by the game/World.
## Move this marker above the desired spawn; instance its scene into any map.
@export var enable_preview_lighting: bool=true
@export var fall_reset_distance: float=60.0
var player: PlayerActor3D
var rig: MandateCamera3D
var _spawn: Vector3
var _reset_requested:=true
var _focused:=true
var _label: Label

func _ready() -> void:
	if GameMode.is_world_server():
		push_error("Map playtest is a local client tool. Run the map with F6, without --mode=world-server.")
		set_physics_process(false);set_process(false);return
	_spawn=global_position
	player=PlayerActor3D.new()
	player.name="LocalMapWalker"
	player.top_level=true
	player.setup("Map playtest",Color.WHITE)
	add_child(player)
	player.global_position=_spawn+Vector3.UP*2
	rig=MandateCamera3D.new()
	rig.top_level=true
	rig.can_control=func()->bool:return _focused
	add_child(rig)
	_prepare_terrain(get_parent())
	if enable_preview_lighting and _find_environment(get_parent())==null:
		var lighting: WorldVisualEnvironment=preload("res://source/client/world_visuals/world_visual_environment.tscn").instantiate()
		lighting.world_time=WorldTime.authority(preload("res://source/common/gameplay/world_time/world_time_settings.tres"))
		add_child(lighting)
	var canvas:=CanvasLayer.new()
	add_child(canvas)
	_label=Label.new()
	_label.position=Vector2(16,16)
	_label.mouse_filter=Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_outline_color",Color.BLACK)
	_label.add_theme_constant_override("outline_size",5)
	canvas.add_child(_label)
	# Native terrain collision needs a physics frame after initialization.
	set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	set_physics_process(true)

func _prepare_terrain(node: Node) -> void:
	if node==self: return
	if node.is_class("Terrain3D"):
		# Runtime-only Full/Game collision, including the production camera layer.
		var collision: Object=node.get("collision")
		if collision!=null:
			collision.set("mode",3)
			collision.set("layer",17)
			collision.set("mask",0)
		node.call("set_camera",rig.camera)
	for child: Node in node.get_children(): _prepare_terrain(child)

func _find_environment(node: Node) -> WorldEnvironment:
	if node==self: return null
	if node is WorldEnvironment: return node
	for child: Node in node.get_children():
		var found:=_find_environment(child)
		if found!=null: return found
	return null

func _physics_process(delta: float) -> void:
	if player==null: return
	if _reset_requested or player.global_position.y<_spawn.y-fall_reset_distance:
		_reset_requested=false
		var query:=PhysicsRayQueryParameters3D.create(_spawn+Vector3.UP*256,_spawn-Vector3.UP*1024,1)
		var hit: Dictionary=get_world_3d().direct_space_state.intersect_ray(query)
		player.global_position=hit.position+Vector3.UP*0.1 if not hit.is_empty() else _spawn+Vector3.UP*2
		player.velocity=Vector3.ZERO
		player.reset_physics_interpolation()
	var input: Vector2=Input.get_vector("player_move_left","player_move_right","player_move_up","player_move_down") if _focused else Vector2.ZERO
	var direction: Vector2=rig.movement_direction(input)
	player.simulate(delta,direction)
	if player.player_presentation!=null: player.player_presentation.set_locomotion(direction.length_squared()>0.001)

func _process(delta: float) -> void:
	if rig==null or player==null: return
	rig.update_camera(delta,player.global_position,_focused)
	_label.text="MAP PLAYTEST · local only · no servers / DB\nWASD: walk  |  RMB: orbit  |  Wheel: zoom  |  R: respawn  |  Esc: release mouse\nPosition: %.1f, %.1f, %.1f  |  %d FPS" % [player.global_position.x,player.global_position.y,player.global_position.z,Engine.get_frames_per_second()]

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode==KEY_R: _reset_requested=true
		elif event.physical_keycode==KEY_ESCAPE and rig!=null: rig.cancel_orbit()

func _notification(what: int) -> void:
	if what==NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused=false
		if rig!=null: rig.cancel_orbit()
	elif what==NOTIFICATION_APPLICATION_FOCUS_IN: _focused=true

func _exit_tree() -> void:
	if rig!=null: rig.cancel_orbit()
