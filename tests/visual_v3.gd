extends "res://tests/visual_v0.gd"
## Native water/V2 review, no pixel baselines. Reuses real CEF/economy/combat flow.

func run_server() -> void:
	check(world.region.get_node_or_null("Water") == null,"server omits water renderer and submerged visual bed")
	await super.run_server()

func review_world() -> void:
	var visual := world.get_node("WorldVisualEnvironment") as WorldVisualEnvironment
	var water := world.region.get_node("Water") as RegionWater
	check(water != null and water.material_override is ShaderMaterial,"authored custom water in actual First Region")
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
	RenderingServer.viewport_set_measure_render_time(review.get_viewport_rid(),true)
	var camera := Camera3D.new()
	camera.fov = world.gameplay_camera().fov
	camera.far = world.gameplay_camera().far
	camera.near = world.gameplay_camera().near
	camera.cull_mask = 1
	review.add_child(camera)
	camera.make_current()
	var material := water.material_override as ShaderMaterial
	var authored_mesh: Mesh = water.mesh
	var flat := BoxMesh.new()
	flat.size = Vector3(22,0.08,144)
	var old_material := StandardMaterial3D.new()
	old_material.albedo_color = Color("467d91")
	old_material.roughness = 0.9
	var midnight: int = Time.get_unix_time_from_datetime_string("2025-06-21T00:00:00")
	var views: Array[Dictionary] = [
		{"name":"day", "hour":14.0,"eye":Vector3(23,4,-18),"target":Vector3(37,-0.1,-38)},
		{"name":"overhead", "hour":14.0,"eye":Vector3(37,16,-36),"target":Vector3(37,-0.1,-37)},
		{"name":"sunset", "hour":18.5,"eye":Vector3(42,2.4,-20),"target":Vector3(31,-0.1,-42)},
		{"name":"night", "hour":0.0,"eye":Vector3(23,4,-18),"target":Vector3(37,-0.1,-38)},
		{"name":"distant", "hour":14.0,"eye":Vector3(-16,14,8),"target":Vector3(39,0,-48)},
	]
	var timings: Dictionary = {}
	for view: Dictionary in views:
		visual.apply_world_time(midnight + view.hour*3600)
		camera.position = view.eye
		camera.look_at(view.target)
		water.animation_enabled = false
		water.mesh = flat
		water.material_override = old_material
		water.get_node("SubmergedBed").hide()
		await capture_review(review,"%s-before" % view.name)
		if view.name == "day": timings["before"] = await measure_gpu(review)
		water.mesh = authored_mesh
		water.material_override = material
		water.get_node("SubmergedBed").show()
		# First review core before fine normals/refraction/foam.
		if view.name == "day":
			material.set_shader_parameter("normal_strength",0.0)
			material.set_shader_parameter("refraction_strength",0.0)
			material.set_shader_parameter("foam_strength",0.0)
			await capture_review(review,"day-core")
			material.set_shader_parameter("normal_strength",0.16)
			material.set_shader_parameter("refraction_strength",0.003)
			material.set_shader_parameter("foam_strength",0.65)
		water.animation_enabled = true
		await capture_review(review,"%s-after" % view.name)
		if view.name == "day": timings["after"] = await measure_gpu(review)
	# Full moon date supplies real V2 moon light rather than a fake water highlight.
	visual.apply_world_time(Time.get_unix_time_from_datetime_string("2025-06-11T00:00:00"))
	var moon_direction: Vector3 = visual.moon.position.normalized()
	var moon_target := Vector3(37,-0.1,-36)
	camera.position = moon_target + Vector3(-moon_direction.x,maxf(moon_direction.y,0.12),-moon_direction.z)*16.0
	camera.look_at(moon_target)
	await capture_review(review,"moon-after")
	visual.apply_world_time(midnight+18.5*3600)
	camera.position = Vector3(42,2.4,-20)
	camera.look_at(Vector3(31,-0.1,-42))
	var frames_path: String = "res://.godot/verification/visual-v3-water-motion"
	DirAccess.make_dir_recursive_absolute(frames_path)
	for step: int in 32:
		await get_tree().create_timer(0.125).timeout
		await RenderingServer.frame_post_draw
		check(review.get_texture().get_image().save_png("%s/frame-%04d.png" % [frames_path,step]) == OK,"native animated water frame")
	# Animated distant views support temporal aliasing review, not pixel assertions.
	camera.position = Vector3(-16,14,8)
	camera.look_at(Vector3(39,0,-48))
	visual.apply_world_time(midnight+14.0*3600)
	var distant_frames: String = "res://.godot/verification/visual-v3-distant-motion"
	DirAccess.make_dir_recursive_absolute(distant_frames)
	for step: int in 24:
		await get_tree().create_timer(0.125).timeout
		await RenderingServer.frame_post_draw
		check(review.get_texture().get_image().save_png("%s/frame-%04d.png" % [distant_frames,step]) == OK,"native distant water frame")
	# Use the production orbit rig/default zoom and pitch at a valid shore position.
	var shore_rig := MandateCamera3D.new()
	shore_rig.settings = world.camera_controller.settings
	review.add_child(shore_rig)
	shore_rig.desired_yaw = -PI/2.0
	shore_rig.camera.far = world.gameplay_camera().far
	shore_rig.camera.cull_mask = 1
	for frame: int in 30:
		shore_rig.update_camera(1.0/60.0,Vector3(23,0,-36),false)
		await get_tree().process_frame
	await capture_review(review,"gameplay-shore")
	var gameplay_frames: String = "res://.godot/verification/visual-v3-gameplay-motion"
	DirAccess.make_dir_recursive_absolute(gameplay_frames)
	for step: int in 24:
		await get_tree().create_timer(0.125).timeout
		await RenderingServer.frame_post_draw
		check(review.get_texture().get_image().save_png("%s/frame-%04d.png" % [gameplay_frames,step]) == OK,"native production camera water frame")
	var report := FileAccess.open("res://.godot/verification/visual-v3-water-gpu.json",FileAccess.WRITE)
	report.store_string(JSON.stringify(timings,"\t"))
	report.close()
	visual.world_time = live_clock
	visual.apply_world_time(live_clock.unix_time())
	for overlay: MeshInstance3D in overlays: overlay.show()
	review.queue_free()
	await get_tree().process_frame
	print("VISUAL_V3_WATER_OK: actual surface/depth/sky/V2 day-sunset-night-moon review, motion/distance and paired GPU sample ",timings)

func capture_review(viewport: SubViewport, label: String) -> void:
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png("res://.godot/verification/%s-%s-%s.png" % [capture_prefix(),CmdlineUtils.get_parsed_args().get("v0-renderer","unknown"),label]) == OK,"water native review capture")

func measure_gpu(viewport: SubViewport) -> Dictionary:
	var values: Array[float] = []
	for sample: int in 90:
		await RenderingServer.frame_post_draw
		values.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid()))
	values.sort()
	return {"frames":values.size(),"median_ms":values[values.size()/2],"p95_ms":values[int(values.size()*0.95)]}
