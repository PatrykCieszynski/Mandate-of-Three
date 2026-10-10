extends Node3D
var _failed := false
var avatars: Array[WarriorVisual3D] = []
var _clips: Array[StringName] = [&"idle",&"run",&"attack_1",&"attack_2",&"attack_3",&"hit",&"death"]
var _interactive := false
func check(value: bool, message: String) -> void:
	if not value:
		push_error(message)
		_failed = true
func _ready() -> void:
	_interactive = OS.get_cmdline_user_args().has("--preview")
	var require_dev := OS.get_cmdline_user_args().has("--require-dev")
	for armored: bool in [false,true]:
		var view := WarriorVisual3D.new()
		view.visual_id = &"warrior_armor" if armored else &"warrior"
		view.tint = Color("779ec5") if armored else Color("c99f71")
		view.equipped = true
		view.position.x = 0.9 if armored else -0.9
		add_child(view)
		avatars.append(view)
	await get_tree().process_frame
	for view: WarriorVisual3D in avatars:
		check(view.content != null and view.weapon != null,"body and sword resolve")
		check(view.content.find_children("*","CollisionObject3D",true,false).is_empty(),"visual has no collision")
		if require_dev:
			check(view.player != null and view.skeleton != null,"animated rig")
			check(view.skeleton.get_bone_count() == (76 if view.visual_id == &"warrior_armor" else 75),"bone count by variant")
			check(view.socket is BoneAttachment3D and (view.socket as BoneAttachment3D).bone_name == "equip_right_hand","native hand socket")
			check(view.weapon.scale.is_equal_approx(Vector3.ONE * 100),"metres to centimetres socket compensation")
			var meshes := view.content.find_children("*","MeshInstance3D",true,false)
			check(meshes.size() == (6 if view.visual_id == &"warrior_armor" else 5),"body, face, hair and attached sword")
			for mesh: MeshInstance3D in meshes:
				for surface: int in mesh.mesh.get_surface_count():
					var material := mesh.get_active_material(surface) as StandardMaterial3D
					check(material != null and material.albedo_texture != null,"resolved embedded material")
					if mesh.name.to_lower().contains("hair"):
						check(material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR,"hair alpha cutout")
			# Facing belongs to the character body, not a run -> idle clip change.
			var root_bone := 0
			view.player.play(&"run",0)
			view.player.advance(0)
			var running_right := Basis(view.skeleton.get_bone_pose_rotation(root_bone)).x
			view.player.play(&"idle",0)
			view.player.advance(0)
			var idle_right := Basis(view.skeleton.get_bone_pose_rotation(root_bone)).x
			check(Vector2(running_right.x,running_right.z).normalized().dot(Vector2(idle_right.x,idle_right.z).normalized()) > 0.99,"stopping preserves locomotion heading")
			for clip: StringName in _clips:
				check(view.player.has_animation(clip),"clip " + str(clip))
				var animation := view.player.get_animation(clip)
				check(animation.loop_mode == (Animation.LOOP_LINEAR if clip in [&"idle",&"run"] else Animation.LOOP_NONE),"loop policy")
				for track: int in animation.get_track_count():
					var path := animation.track_get_path(track)
					if animation.track_get_type(track) != Animation.TYPE_POSITION_3D or path.get_subname_count()==0: continue
					var bone := view.skeleton.find_bone(path.get_subname(0))
					if bone < 0 or view.skeleton.get_bone_parent(bone) != -1: continue
					var first: Vector3 = animation.track_get_key_value(track,0)
					for key: int in animation.track_get_key_count(track):
						var value: Vector3 = animation.track_get_key_value(track,key)
						check(is_equal_approx(value.x,first.x) and is_equal_approx(value.z,first.z),"in-place planar root")
				view.player.play(clip,0)
				view.player.advance(animation.length * 0.5)
				view.player.pause()
				view.skeleton.force_update_all_bone_transforms()
				await get_tree().process_frame
				await get_tree().process_frame
				var bone := view.skeleton.find_bone("equip_right_hand")
				var expected := view.skeleton.global_transform * view.skeleton.get_bone_global_pose(bone)
				check(view.socket.global_position.distance_to(expected.origin) < 0.001,"socket follows animated hand")
				if clip == &"idle":
					var blade_direction := (view.weapon.global_basis * Vector3.UP).normalized()
					check(blade_direction.dot(Vector3.UP) > 0.5,"sword blade points upward in idle for both variants")
		view.set_locomotion(true)
		view.play_attack(1)
		check(view.animation_state == &"attack_1","first combo")
		view.play_attack(2)
		check(view.animation_state == &"attack_2","second combo")
		view.play_attack(3)
		check(view.animation_state == &"attack_3","third combo")
		view.play_hit()
		check(view.animation_state == &"hit","hit")
		view._process(2)
		check(view.animation_state == &"run","hit resumes running")
		view.set_alive(false)
		check(view.animation_state == &"death" and not view.weapon.visible,"death")
		view.play_attack(1)
		check(view.animation_state == &"death","death cannot be interrupted")
		view.set_alive(true)
		check(view.weapon.visible and view.animation_state == &"run","respawn")
		view.set_variant(view.visual_id != &"warrior_armor")
		check(view.weapon != null and view.alive,"armor swap keeps equipped sword")
		print("WARRIOR_VARIANT_OK ",view.visual_id)
		view.set_variant(view.position.x > 0)
	var body := SpikeCharacter3D.new()
	body.setup("Compatibility player",Color("c99f71"))
	body.position = Vector3(3,0,2)
	add_child(body)
	body.set_weapon("iron_sword")
	await get_tree().process_frame
	var collider := body.get_children().filter(func(node): return node is CollisionShape3D)[0] as CollisionShape3D
	check(is_equal_approx(collider.shape.radius,0.35) and is_equal_approx(collider.shape.height,1.8),"player collider unchanged")
	check(body.collision_layer == 2 and body.collision_mask == 1 and body.player_presentation.equipped,"existing entity uses visual and original collision")
	body.play_swing(2)
	check(body.player_presentation.animation_state == &"attack_2","existing swing event selects combo")
	body.play_hit()
	check(body.player_presentation.animation_state == &"hit","existing hit event")
	body.set_alive(false)
	check(not body.alive and body.player_presentation.animation_state == &"death","existing death event")
	body.set_alive(true)
	check(body.alive and body.position == Vector3(3,0,2) and body.weapon_definition_id == "iron_sword","visuals do not move or unequip body")
	if OS.get_cmdline_user_args().has("--no-dev-visuals"):
		check(body.player_presentation.content.scene_file_path == VisualResolver.PLACEHOLDER_WARRIOR,"tracked body fallback")
		check(body.player_presentation.weapon.scene_file_path == VisualResolver.PLACEHOLDER_SWORD,"tracked sword fallback")
	if require_dev and OS.get_cmdline_user_args().has("--remove-live"):
		var originals: Array[String] = [ProjectSettings.globalize_path(VisualResolver.paths(&"warrior")[1]),ProjectSettings.globalize_path(VisualResolver.paths(&"iron_sword")[1])]
		var stashes: Array[String] = [ProjectSettings.globalize_path("res://.godot/verification/warrior-hot-body.glb"),ProjectSettings.globalize_path("res://.godot/verification/warrior-hot-sword.glb")]
		for i: int in 2:
			check(not FileAccess.file_exists(stashes[i]),"hot stash is empty")
			check(DirAccess.rename_absolute(originals[i],stashes[i]) == OK,"temporarily remove local asset")
		await get_tree().create_timer(.35).timeout
		var fallback_ok := body.player_presentation.content.scene_file_path == VisualResolver.PLACEHOLDER_WARRIOR and body.player_presentation.weapon.scene_file_path == VisualResolver.PLACEHOLDER_SWORD
		var state_ok := body.position == Vector3(3,0,2) and body.alive and body.player_presentation.equipped and body.collision_layer == 2
		for i: int in 2: check(DirAccess.rename_absolute(stashes[i],originals[i]) == OK,"restore selected asset")
		await get_tree().create_timer(.35).timeout
		check(fallback_ok and state_ok,"live body and sword deletion preserves gameplay")
		check(body.player_presentation.content.scene_file_path == VisualResolver.paths(&"warrior")[1],"live restaging restores model")
	body.free()
	if _failed:
		get_tree().quit(1)
		return
	if _interactive or OS.get_cmdline_user_args().has("--capture"):
		_setup_stage()
		await get_tree().process_frame
		if not _interactive:
			for clip: StringName in _clips:
				_pose(clip)
				await get_tree().process_frame
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png("res://.godot/verification/warrior-"+str(clip)+".png")
	if _interactive:
		_pose(&"idle",false)
		print("WARRIOR_PREVIEW_READY")
		return
	for view: WarriorVisual3D in avatars: view.free()
	print("WARRIOR_COMPATIBILITY_OK")
	get_tree().quit()
func _pose(clip: StringName, frozen: bool = true) -> void:
	for view: WarriorVisual3D in avatars:
		view.alive = true
		view._shot = &""
		view._play(clip,true)
		view.weapon.visible = true
		if view.player != null:
			view.player.play(clip,0)
			if frozen:
				view.player.advance(view.player.get_animation(clip).length * (0.95 if clip == &"death" else 0.5))
				view.player.pause()
				view.skeleton.force_update_all_bone_transforms()
func _setup_stage() -> void:
	var plane := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(7,7)
	plane.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15,0.17,0.20)
	plane.material_override = mat
	add_child(plane)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45,-30,0)
	light.light_energy = 1.5
	add_child(light)
	var camera := Camera3D.new()
	camera.position = Vector3(3.0,2.3,-4.5)
	add_child(camera)
	camera.look_at(Vector3(0,1,0))
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.07,0.09,0.12)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = .6
	add_child(environment)
	var label := Label.new()
	label.text = "Warrior: base + armor | 1 idle  2 run  3/4/5 combo  6 hit  7 death | V swap armor | Esc close"
	label.position = Vector2(16,16)
	add_child(label)
func _unhandled_key_input(event: InputEvent) -> void:
	if not _interactive or not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode >= KEY_1 and event.keycode <= KEY_7: _pose(_clips[event.keycode-KEY_1],false)
	elif event.keycode == KEY_V:
		for view: WarriorVisual3D in avatars: view.set_variant(view.visual_id != &"warrior_armor")
	elif event.keycode == KEY_ESCAPE: get_tree().quit()
