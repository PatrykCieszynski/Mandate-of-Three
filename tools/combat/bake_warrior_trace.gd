extends SceneTree
## Offline only: load the production presentation, then save gameplay Resources.
func _initialize() -> void:
	call_deferred("_bake")

func _bake() -> void:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/combat/warrior-trace-bake.json"))
	var fixture := Node3D.new()
	root.add_child(fixture)
	var view := WarriorVisual3D.new()
	view.visual_id = &"warrior"
	view.equipped = true
	fixture.add_child(view)
	view.set_process(false)
	if view.player == null or not view.socket is BoneAttachment3D or view.weapon == null:
		push_error("Real local Warrior and hand socket required; no placeholder bake")
		quit(1)
		return
	print("TRACE_BAKE_RIG skeleton=",view.skeleton.get_path()," socket_bone=",view.socket.bone_name," weapon=",view.weapon.get_path())
	view.player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var output := "res://source/common/gameplay/combat/traces"
	DirAccess.make_dir_recursive_absolute(output)
	for step: Dictionary in config.steps:
		assert(view.player.has_animation(step.clip))
		var trace := CombatTraceDefinition.new()
		trace.radius = config.radius
		for i: int in int(config.sample_count):
			var time := int(round(lerpf(step.start_ms,step.end_ms,i/float(config.sample_count-1))))
			await _pose(view,StringName(step.clip),time)
			var points := _blade(view,float(config.weapon_length_m))
			var sample := CombatTraceSample.new()
			sample.time_ms = time
			sample.base = points[0]
			sample.tip = points[1]
			trace.samples.append(sample)
		assert(trace.valid(step.start_ms,step.end_ms))
		# Translation/yaw of the preview must never leak into the baked coordinates.
		var baseline := _blade(view,float(config.weapon_length_m))
		view.position = Vector3(31,4,-17)
		view.rotation.y = 1.1
		await _pose(view,StringName(step.clip),step.end_ms)
		var placed := _blade(view,float(config.weapon_length_m))
		assert(placed[0].is_equal_approx(baseline[0]) and placed[1].is_equal_approx(baseline[1]),"Actor-local bake is placement invariant")
		view.transform = Transform3D.IDENTITY
		var path: String = output+"/"+step.clip+".tres"
		assert(ResourceSaver.save(trace,path) == OK)
		print("TRACE_BAKED ",step.clip," samples=",trace.samples.size()," bounds=",trace.bounds())
	fixture.free()
	print("WARRIOR_TRACE_BAKE_OK")
	quit()

func _pose(view: WarriorVisual3D, clip: StringName, time_ms: int) -> void:
	view.player.stop()
	view.player.play(clip,0.0)
	view.player.advance(time_ms/1000.0)
	view.skeleton.force_update_all_bone_transforms()
	await process_frame
	await process_frame

func _blade(view: WarriorVisual3D, length_m: float) -> PackedVector3Array:
	# Sword is authored along +Y, with the production grip correction already applied.
	# No mesh bounds/vertices: origin and transformed gameplay length only.
	var origin := view.weapon.global_position
	var tip := origin + view.weapon.global_basis.y.normalized()*length_m
	return PackedVector3Array([view.to_local(origin),view.to_local(tip)])
