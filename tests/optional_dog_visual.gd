extends Node3D
var _failed := false
## Same gameplay entity in every source mode. No legacy assets needed by this test.

func check(value: bool, message: String) -> void:
	if not value:
		push_error(message)
		_failed = true

func _ready() -> void:
	var expected := "placeholder"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--visual-expect="): expected = arg.get_slice("=",1)
	var scene := VisualResolver.resolve(&"stray_dog")
	var expected_path := VisualResolver.PLACEHOLDER_DOG
	if expected == "dev": expected_path = VisualResolver.DEV_DOG
	elif expected == "final": expected_path = VisualResolver.FINAL_DOG
	check(scene != null and scene.resource_path == expected_path, "resolution priority " + expected)
	check(VisualResolver.resolve(&"unknown") == null, "unknown logical IDs do not load files")
	scene = null # The live presenter must retain its own resource, not this fixture.
	var dog := SpikeWildDog3D.new()
	dog.setup_dog(9, Vector3(3,0,2))
	add_child(dog)
	await get_tree().process_frame
	var view := dog.presentation
	check(ResourceLoader.has_cached(expected_path), "live visuals retain scenes for repeated development polls")
	check(view.content.scene_file_path == expected_path, "existing gameplay dog uses selected visual")
	check(dog.hp == 120 and dog.collision_layer == 4, "gameplay spawn unaffected")
	var collision := dog.get_children().filter(func(node): return node is CollisionShape3D)[0] as CollisionShape3D
	check(is_equal_approx(collision.shape.radius,0.4) and is_equal_approx(collision.shape.height,0.8), "authoritative collider remains fixed")
	check(view.content.find_children("*","CollisionObject3D",true,false).is_empty(), "visual contains no collision")
	var position_before := dog.position
	var yaw_before := dog.rotation.y
	view.set_locomotion("IDLE", false)
	check(view.animation_state == &"idle", "idle state")
	view.set_locomotion("CHASE", true)
	check(view.animation_state == &"run", "run state")
	view.set_locomotion("ATTACK", false)
	check(view.animation_state == &"attack", "attack state from existing AI snapshot")
	dog.play_hit()
	check(view.animation_state == &"hit", "hit event")
	view._process(1.0)
	check(view.animation_state == &"attack", "hit resumes current locomotion")
	if expected == "dev":
		check(view.player != null, "animation player imported")
		var skeleton := view.content.find_children("*","Skeleton3D",true,false)[0] as Skeleton3D
		check(skeleton.get_bone_count() == 38, "38 bones")
		var mesh := view.content.find_children("*","MeshInstance3D",true,false)[0] as MeshInstance3D
		var material := mesh.get_active_material(0) as StandardMaterial3D
		check(material != null and material.albedo_texture != null, "material and texture imported")
		check(material.albedo_texture.get_width() == 512, "DDS-derived texture size")
		for clip: StringName in [&"idle",&"run",&"attack",&"hit",&"death"]:
			check(view.player.has_animation(clip), "clip " + str(clip))
			var animation := view.player.get_animation(clip)
			var roots_checked := 0
			for track: int in animation.get_track_count():
				var path := animation.track_get_path(track)
				if animation.track_get_type(track) != Animation.TYPE_POSITION_3D or path.get_subname_count()==0: continue
				var bone := skeleton.find_bone(path.get_subname(0))
				if bone < 0 or skeleton.get_bone_parent(bone) != -1: continue
				roots_checked += 1
				var origin: Vector3 = animation.track_get_key_value(track,0)
				for key: int in animation.track_get_key_count(track):
					var sample: Vector3 = animation.track_get_key_value(track,key)
					check(is_equal_approx(origin.x,sample.x) and is_equal_approx(origin.z,sample.z), "planar root displacement removed")
			check(roots_checked == 1,"root position track found")
		check(view.player.get_animation(&"idle").loop_mode == Animation.LOOP_LINEAR,"idle loops")
		check(view.player.get_animation(&"run").loop_mode == Animation.LOOP_LINEAR,"run loops")
	dog.present_snapshot([dog.mob_instance_id,dog.position,dog.rotation.y,0,MobSnapshot.State.DEAD,dog.mob_key,""])
	check(dog.ai_state == "DEAD" and dog.collision_layer == 0,"death disables collision immediately")
	check(view.animation_state == &"death" and view.visible,"death presentation")
	dog.present_snapshot([dog.mob_instance_id,dog.position,dog.rotation.y,0,MobSnapshot.State.DEAD,dog.mob_key,""])
	view._process(1.1)
	check(not view.visible,"corpse hides after presentation without affecting server respawn")
	dog.present_snapshot([dog.mob_instance_id,dog.position,dog.rotation.y,120,MobSnapshot.State.IDLE,dog.mob_key,""])
	check(view.visible and dog.collision_layer == 4,"respawn restores presentation and original collision")
	check(dog.position == position_before and dog.rotation.y == yaw_before,"clips never move gameplay body")
	check(dog.home == Vector3(3,0,2) and dog.knockback == Vector3.ZERO,"visuals do not mutate gameplay state")
	if expected == "dev" and OS.get_cmdline_user_args().has("--visual-remove-live"):
		var original := ProjectSettings.globalize_path(VisualResolver.DEV_DOG)
		var temporary := ProjectSettings.globalize_path("res://.godot/verification/visual-hot-stash.glb")
		check(not FileAccess.file_exists(temporary), "hot-reload stash must be empty")
		check(DirAccess.rename_absolute(original,temporary) == OK, "temporarily remove local source")
		await get_tree().create_timer(0.35).timeout
		var fell_back := view.content.scene_file_path == VisualResolver.PLACEHOLDER_DOG
		var unchanged := dog.hp == 120 and dog.collision_layer == 4 and dog.position == position_before
		var restored := DirAccess.rename_absolute(temporary,original) == OK
		check(restored, "restore local source")
		await get_tree().create_timer(0.35).timeout
		check(fell_back and unchanged, "live deletion falls back without changing gameplay")
		check(view.content.scene_file_path == VisualResolver.DEV_DOG, "restaging returns to local visual")
	dog.free()
	# Exercise full-list reconciliation without booting game input/UI or a server.
	var snapshot_world := SpikeWorld3D.new()
	var combat := SpikeCombat3D.new()
	combat._world = snapshot_world
	var record: Array = [101,Vector3(4,0,2),0.5,80,MobSnapshot.State.IDLE,&"feral_dog","stone-test"]
	combat._receive_mob_snapshots([record])
	var replicated: SpikeWildDog3D = combat.dogs[101]
	check(replicated.definition == MobDefinitions.FERAL_DOG and replicated.max_hp == MobDefinitions.FERAL_DOG.max_hp and replicated.title == MobDefinitions.FERAL_DOG.display_name, "new actor uses local presentation definition")
	check(replicated.hp == 80 and replicated.source_metinstone_id == "stone-test", "dynamic fields and provenance survive reconciliation")
	check(replicated.pack_instance_id == 0, "client has no replicated pack runtime")
	record[MobSnapshot.Field.HP] = 60
	combat._receive_mob_snapshots([record])
	check(combat.dogs[101] == replicated and replicated.hp == 60, "later full snapshot updates existing actor")
	combat._receive_mob_snapshots([])
	check(combat.dogs.is_empty(), "empty full snapshot removes all actors")
	combat._receive_mob_snapshots([record])
	check(combat.dogs[101] != replicated and combat.dogs[101].hp == 60, "full snapshot can reconstruct after removal")
	snapshot_world.free()
	combat.free()
	await get_tree().process_frame
	if _failed:
		get_tree().quit(1)
		return
	print("OPTIONAL_DOG_VISUAL_OK ",expected)
	get_tree().quit(0)
