extends "res://tests/visual_v0.gd"
## Native milestone review only: same world/camera before/after, no pixel assertions.

func run_server() -> void:
	check(world.get_node_or_null("WorldVisualEnvironment") == null, "server omits visual environment/time/render nodes")
	await super.run_server()

func review_world() -> void:
	await compare_environment()

func compare_environment() -> void:
	var visual := world.get_node("WorldVisualEnvironment") as WorldVisualEnvironment
	# V1 remains a repeatable fixed reference review after V2 enables world time.
	var live_clock: WorldTime = visual.world_time
	visual.world_time = null
	visual.apply_world_time(1750519800.0)
	var clock_time: float = visual.current_time
	check(visual.environment.background_mode == Environment.BG_SKY and visual.environment.tonemap_mode == Environment.TONE_MAPPER_AGX, "native Sky3D + AgX composition")
	check(visual.sun.light_energy > 0 and visual.sun.shadow_enabled, "Sky3D owns a lit shadow-casting DirectionalLight3D")
	# Stop cloud motion only in this review fixture, for comparable captures.
	var cloud_process: int = visual.sky.process_method
	visual.sky.process_method = 2
	# Respect the user's local trace toggle; hide its overlays only during review.
	var overlays: Array[MeshInstance3D] = []
	for mesh: MeshInstance3D in world.find_children("*","MeshInstance3D",true,false):
		if mesh is CombatTraceDebug3D and mesh.visible:
			overlays.append(mesh)
			mesh.hide()
	# Share the actual live world, but use a review viewport with no UI/follow rig.
	var review := SubViewport.new()
	review.size = Vector2i(1280,720)
	review.world_3d = world.get_world_3d()
	review.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(review)
	var camera := Camera3D.new()
	camera.fov = world.gameplay_camera().fov
	camera.far = world.gameplay_camera().far
	camera.near = world.gameplay_camera().near
	camera.cull_mask = 1 # Authored world/actors only, omit editor/debug layers in review.
	review.add_child(camera)
	camera.make_current()
	var original_transform: Transform3D = world.gameplay_camera().global_transform
	var legacy := Environment.new()
	legacy.background_mode = Environment.BG_COLOR
	legacy.background_color = Color("172531")
	legacy.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	legacy.ambient_light_color = Color("c2d6ea")
	legacy.ambient_light_energy = 0.65
	var old_sun := DirectionalLight3D.new()
	old_sun.rotation_degrees = Vector3(-55,-30,0)
	old_sun.light_energy = 1.2
	old_sun.shadow_enabled = true
	old_sun.hide()
	world.add_child(old_sun)
	var views: Array[Dictionary] = [
		{"name":"hub", "position":original_transform.origin, "basis":original_transform.basis},
		{"name":"region", "position":Vector3(18,11,34), "target":Vector3(0,3,-65)},
		{"name":"outskirts", "position":Vector3(-21,8,3), "target":Vector3(-15,2,-19)},
		{"name":"horizon", "position":Vector3(0,7,18), "target":Vector3(0,5,-50)},
	]
	for view: Dictionary in views:
		camera.global_position = view.position
		if view.has("target"): camera.look_at(view.target)
		else: camera.global_basis = view.basis
		camera.environment = legacy
		visual.sun.hide()
		old_sun.show()
		await capture_review(review,"%s-before" % view.name)
		camera.environment = visual.environment
		old_sun.hide()
		visual.sun.show()
		await capture_review(review,"%s-after" % view.name)
	check(is_equal_approx(clock_time,15.5) and is_equal_approx(visual.current_time,clock_time), "reference 15:30 remains fixed across native review")
	old_sun.queue_free()
	review.queue_free()
	visual.sky.process_method = cloud_process
	visual.world_time = live_clock
	for overlay: MeshInstance3D in overlays: overlay.show()
	await get_tree().process_frame
	print("VISUAL_V1_ENVIRONMENT_OK: fixed 15:30, procedural sky/AgX/sun, four native before/after views")

func capture_review(viewport: SubViewport, label: String) -> void:
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	var path: String = "res://.godot/verification/%s-%s-%s.png" % [capture_prefix(),CmdlineUtils.get_parsed_args().get("v0-renderer","unknown"),label]
	check(viewport.get_texture().get_image().save_png(path) == OK,"world review capture")
