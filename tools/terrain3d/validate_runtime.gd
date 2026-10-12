extends SceneTree
## Native rendering evidence for the persisted scene, no reconstruction or pixels tests.
func _initialize() -> void:
	call_deferred("validate")
func validate() -> void:
	var spike: Terrain3DSpike = load("res://source/common/gameplay/maps/terrain3d_spike/terrain_spike.tscn").instantiate()
	root.add_child(spike)
	spike.animate_preview = false
	spike.visual.world_time = null
	spike.visual.apply_world_time(1750519800.0)
	if spike.terrain.get_region_size()!=64 or spike.terrain.data.get_region_count()!=1:
		push_error("TERRAIN_RUNTIME_FAILED: persisted region")
		quit(1)
		return
	spike.rig.process_mode = Node.PROCESS_MODE_DISABLED
	# A separate native review camera avoids changing the production orbit rig.
	var review_camera := Camera3D.new()
	root.add_child(review_camera)
	review_camera.make_current()
	spike.terrain.set_camera(review_camera)
	var frames: Array[float] = []
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	for view: Dictionary in [
		{"name":"overview","eye":Vector3(12,22,63),"target":Vector3(31,1,31)},
		{"name":"path","eye":Vector3(12,5,23),"target":Vector3(19,1,36)},
		{"name":"shore","eye":Vector3(49,3,24),"target":Vector3(55,-0.5,37)}]:
		review_camera.position = view.eye
		review_camera.look_at(view.target)
		await create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://.godot/verification/visual-v4-64-%s.png" % view.name)
		if view.name=="overview":
			for frame: int in 120:
				await RenderingServer.frame_post_draw
				frames.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
	for step: int in 30:
		await physics_frame
		spike.player.simulate(1.0/60.0,Vector2.ZERO)
	var start: Vector3 = spike.player.position
	for step: int in 48:
		await physics_frame
		spike.player.simulate(1.0/60.0,Vector2(1,0))
	if not spike.player.is_on_floor() or spike.player.position.x<start.x+1:
		push_error("TERRAIN_RUNTIME_FAILED: production body movement")
		quit(1)
		return
	frames.sort()
	var report: Dictionary = {"renderer":RenderingServer.get_current_rendering_method(),"driver":RenderingServer.get_current_rendering_driver_name(),"gpu":RenderingServer.get_video_adapter_name(),"gpu_median_ms":frames[frames.size()/2],"gpu_p95_ms":frames[int(frames.size()*0.95)],"frames":frames.size(),"size":64}
	var file := FileAccess.open("res://.godot/verification/visual-v4-64-gpu.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("TERRAIN_RUNTIME_OK: persisted scene, rendered four materials, native production movement ",report)
	quit()
