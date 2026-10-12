extends "res://tests/visual_v0.gd"
## Native full 24h review; images/video are milestone artifacts, not pixel tests.

func run_server() -> void:
	check(world.get_node_or_null("WorldVisualEnvironment") == null,"server keeps only calendar, no sky renderer")
	await super.run_server()

func review_world() -> void:
	var visual := world.get_node("WorldVisualEnvironment") as WorldVisualEnvironment
	check(world.world_time.clock.synchronized,"real native client receives World Server calendar")
	var live_clock: WorldTime = visual.world_time
	visual.world_time = null
	var overlays: Array[MeshInstance3D] = []
	for mesh: MeshInstance3D in world.find_children("*","MeshInstance3D",true,false):
		if mesh is CombatTraceDebug3D and mesh.visible:
			overlays.append(mesh)
			mesh.hide()
	var review := SubViewport.new()
	review.size = Vector2i(1280,720)
	review.world_3d = world.get_world_3d()
	review.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(review)
	var camera := Camera3D.new()
	camera.fov = world.gameplay_camera().fov
	camera.far = world.gameplay_camera().far
	camera.near = world.gameplay_camera().near
	camera.cull_mask = 1
	review.add_child(camera)
	camera.make_current()
	camera.position = Vector3(18,11,34)
	camera.look_at(Vector3(0,3,-65))
	var midnight: int = Time.get_unix_time_from_datetime_string("2025-06-21T00:00:00")
	for hour: float in [0.0,4.5,5.5,6.5,12.0,15.5,18.5,19.5,21.0]:
		visual.apply_world_time(midnight+hour*3600.0)
		await capture_review(review,"hour-%04d" % int(hour*100))
	# Inspect the actual textured moon/phases on a known full-moon calendar date.
	visual.apply_world_time(Time.get_unix_time_from_datetime_string("2025-06-11T00:00:00"))
	var moon_direction: Vector3 = visual.moon.position.normalized()
	camera.position = Vector3(0,7,18)
	camera.look_at(camera.position+moon_direction*100.0)
	await capture_review(review,"moon")
	check(visual.moon.light_energy > 0 and visual.moon_phase > 0.9 and visual.star_visibility > 0.9,"full-moon calendar drives moon phase/light and stars")
	camera.position = Vector3(18,11,34)
	camera.look_at(Vector3(0,3,-65))
	var frames_path: String = "res://.godot/verification/visual-v2-timelapse"
	DirAccess.make_dir_recursive_absolute(frames_path)
	var previous_sun: Vector3
	var previous_exposure: float
	for step: int in 721:
		visual.apply_world_time(midnight+step*120.0)
		if step > 0:
			check(previous_sun.distance_to(visual.sun.position) < 0.025,"no sun jump across full calendar cycle")
			check(absf(previous_exposure-visual.environment.tonemap_exposure) < 0.08,"continuous exposure at dawn/dusk/midnight")
		previous_sun = visual.sun.position
		previous_exposure = visual.environment.tonemap_exposure
		await get_tree().create_timer(0.016).timeout
		if step % 8 == 0:
			await RenderingServer.frame_post_draw
			check(review.get_texture().get_image().save_png("%s/frame-%04d.png" % [frames_path,step/8]) == OK,"timelapse frame")
	visual.world_time = live_clock
	visual.apply_world_time(live_clock.unix_time())
	for overlay: MeshInstance3D in overlays: overlay.show()
	review.queue_free()
	await get_tree().process_frame
	print("VISUAL_V2_CYCLE_OK: server calendar, dawn/day/dusk/night/moon/stars and 24h continuous native timelapse")

func capture_review(viewport: SubViewport, label: String) -> void:
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png("res://.godot/verification/%s-%s-%s.png" % [capture_prefix(),CmdlineUtils.get_parsed_args().get("v0-renderer","unknown"),label]) == OK,"day/night native capture")
