extends Node3D
var _failed := false
var avatars: Array[WarriorVisual3D] = []
var _clips: Array[StringName] = [&"idle",&"run",&"hit",&"death"]
var _interactive := false
var _review_generation := 0
var _review_label: Label
var _review_humanoid: WarriorVisual3D
var _humanoid_target := false
var _review_dog: DogVisual3D
var _trace_overlays: Array[CombatTraceDebug3D] = []
var _legacy_trace := false
var _review_ratio := 1.0
var _review_skill := 0
var _feel_feedback: CombatFeedback3D
var _feel_targets: Array[MobActor3D] = []
var _feel_actors: Array[Node3D] = []
var _preview_advances: Array[Tween] = []
var _review_single := false
var _review_turn := false
var _preview_camera: MandateCamera3D
func check(value: bool, message: String) -> void:
	if not value:
		push_error(message)
		_failed = true
func _ready() -> void:
	_clips.append_array(BasicAttackCombos.animation_keys())
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
			check(view.validate_combo_animations(),"complete required Warrior combo set")
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
		view.play_basic_attack(&"onehand_sword__combo_01",BasicAttackCombos.BASE.steps[0].recovery_ms)
		check(view.animation_state == &"onehand_sword__combo_01","first combo")
		view.play_basic_attack(&"onehand_sword__combo_02",BasicAttackCombos.BASE.steps[1].recovery_ms)
		check(view.animation_state == &"onehand_sword__combo_02","second combo")
		view.play_basic_attack(&"onehand_sword__combo_03",BasicAttackCombos.BASE.steps[2].recovery_ms)
		check(view.animation_state == &"onehand_sword__combo_03","third combo")
		view.play_hit()
		check(view.animation_state == &"onehand_sword__combo_03","flinch does not replace an ongoing combo swing")
		view._process(2)
		check(view.animation_state == &"run","swing resumes running despite flinch")
		view.play_hit()
		check(view.animation_state == &"hit","flinch outside a swing uses the hit clip")
		view.set_hit_lock(1.2,0.4)
		view._process(0)
		check(view.animation_state == &"knockdown","server lock drives fall presentation")
		view.set_hit_lock(0,0.4)
		view._process(0)
		check(view.animation_state == &"get_up","server get-up phase drives presentation")
		view.set_hit_lock(0,0)
		view._process(0)
		check(view.animation_state == &"run","unlock restores locomotion")
		view.set_alive(false)
		check(view.animation_state == &"death" and not view.weapon.visible,"death")
		view.play_basic_attack(&"onehand_sword__combo_01",BasicAttackCombos.BASE.steps[0].recovery_ms)
		check(view.animation_state == &"death","death cannot be interrupted")
		view.set_alive(true)
		check(view.weapon.visible and view.animation_state == &"run","respawn")
		view.set_variant(view.visual_id != &"warrior_armor")
		check(view.weapon != null and view.alive,"armor swap keeps equipped sword")
		print("WARRIOR_VARIANT_OK ",view.visual_id)
		view.set_variant(view.position.x > 0)
	var body := PlayerActor3D.new()
	body.setup("Compatibility player",Color("c99f71"))
	body.position = Vector3(3,0,2)
	add_child(body)
	body.set_weapon("iron_sword")
	await get_tree().process_frame
	var collider := body.get_children().filter(func(node): return node is CollisionShape3D)[0] as CollisionShape3D
	check(is_equal_approx(collider.shape.radius,0.35) and is_equal_approx(collider.shape.height,1.8),"player collider unchanged")
	check(body.collision_layer == 2 and body.collision_mask == 1 and body.player_presentation.equipped,"existing entity uses visual and original collision")
	body.play_swing(&"onehand_sword__combo_02",BasicAttackCombos.BASE.steps[1].recovery_ms)
	check(body.player_presentation.animation_state == &"onehand_sword__combo_02","existing swing event selects combo")
	body.play_hit()
	check(body.player_presentation.animation_state == &"onehand_sword__combo_02","existing flinch event preserves the swing")
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
		if OS.get_cmdline_user_args().has("--combo-review"):
			_review_dog = DogVisual3D.new()
			_review_dog.position = Vector3(0,0,-1.5)
			_review_dog.rotation.y = PI
			add_child(_review_dog)
			if OS.get_cmdline_user_args().has("--trace-review"):
				# Put the defender in front of the right-hand reviewer, including the narrow 04.
				_review_dog.position.x = avatars[1].position.x
				_review_humanoid = WarriorVisual3D.new()
				_review_humanoid.position = _review_dog.position
				_review_humanoid.rotation.y = PI
				_review_humanoid.visible = false
				add_child(_review_humanoid)
			_review_label = Label.new()
			_review_label.position = Vector2(16,48)
			add_child(_review_label)
			_review_label.text = "Combo review: 1 base / 2 Combo Lv1 / 3 Combo Lv2. Loops at native speed. Esc closes."
		if OS.get_cmdline_user_args().has("--feel-review"):
			_setup_feel_pack()
		print("WARRIOR_PREVIEW_READY")
		if OS.get_cmdline_user_args().has("--action-capture"):
			_review_ratio = 1.22
			_review_single = true
			_review_generation += 1
			await _review_combo(0,_review_generation)
			_review_single = false
			_review_generation += 1
			await _review_combo(0,_review_generation)
			_review_turn = true
			_review_generation += 1
			await _review_combo(0,_review_generation)
			print("WARRIOR_ACTION_RENDER_OK")
			get_tree().quit()
			return
		if OS.get_cmdline_user_args().has("--feel-capture"):
			for blend: float in [.08,.05]:
				for view: WarriorVisual3D in avatars: view.attack_blend_seconds = blend
				_review_ratio = 1.22
				_review_generation += 1
				await _review_combo(0,_review_generation)
			for ratio: float in [1.0,1.22,1.5]:
				_review_ratio = ratio
				for skill: int in [0,1,2]:
					_review_generation += 1
					await _review_combo(skill,_review_generation)
			print("WARRIOR_FEEL_RENDER_OK")
			get_tree().quit()
			return
		if OS.get_cmdline_user_args().has("--vertical-capture"):
			for humanoid: bool in [false,true]:
				_set_review_target(humanoid)
				_review_generation += 1
				await _review_combo(0,_review_generation)
			print("WARRIOR_VERTICAL_RENDER_OK")
			get_tree().quit()
			return
		if OS.get_cmdline_user_args().has("--combo-capture"):
			for level: int in [0,1,2]:
				_review_generation += 1
				await _review_combo(level,_review_generation)
			print("WARRIOR_COMBO_RENDER_OK")
			get_tree().quit()
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
	mesh.size = Vector2(12,12) if OS.get_cmdline_user_args().has("--feel-review") else Vector2(7,7)
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
	if OS.get_cmdline_user_args().has("--feel-review"):
		_preview_camera = MandateCamera3D.new()
		add_child(_preview_camera)
		_preview_camera.camera.global_position = Vector3(5,5,6)
		_preview_camera.camera.look_at(Vector3(0,1,-2))
		camera.queue_free()
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.07,0.09,0.12)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = .6
	add_child(environment)
	var label := Label.new()
	label.text = "Warrior: base + armor | Combo review: 1/2/3 = 4/5/6 hits | V armor | B blend .08/.05 | Q/E/R AS100/122/150 | S single/chain | G turn each step | T trace/cone | H dog/humanoid | Esc close" if OS.get_cmdline_user_args().has("--combo-review") else "Warrior poses: number keys | V armor | Esc close"
	label.position = Vector2(16,16)
	add_child(label)
func _unhandled_key_input(event: InputEvent) -> void:
	if not _interactive or not event is InputEventKey or not event.pressed or event.echo: return
	if _review_dog != null and event.keycode in [KEY_1,KEY_2,KEY_3]:
		_review_generation += 1
		_review_skill = event.keycode-KEY_1
		_review_combo(_review_skill,_review_generation)
	elif _review_dog == null and event.keycode >= KEY_1 and event.keycode < KEY_1+_clips.size(): _pose(_clips[event.keycode-KEY_1],false)
	elif event.keycode in [KEY_Q,KEY_E,KEY_R] and _review_dog != null:
		_review_ratio = 1.0 if event.keycode == KEY_Q else (1.22 if event.keycode == KEY_E else 1.5)
		_review_generation += 1
		_review_combo(_review_skill,_review_generation)
	elif event.keycode in [KEY_S,KEY_G] and not _feel_actors.is_empty():
		if event.keycode == KEY_S: _review_single = not _review_single
		else: _review_turn = not _review_turn
		_review_generation += 1
		_review_combo(_review_skill,_review_generation)
	elif event.keycode == KEY_B and _review_dog != null:
		for view: WarriorVisual3D in avatars: view.attack_blend_seconds = .05 if view.attack_blend_seconds > .06 else .08
	elif event.keycode == KEY_T and not _trace_overlays.is_empty():
		_legacy_trace = not _legacy_trace
		for overlay: CombatTraceDebug3D in _trace_overlays:
			overlay.legacy = _legacy_trace
			overlay.redraw()
	elif event.keycode == KEY_H and _review_humanoid != null:
		_set_review_target(not _humanoid_target)
		_review_generation += 1
		_review_combo(0,_review_generation)
	elif event.keycode == KEY_V:
		for view: WarriorVisual3D in avatars: view.set_variant(view.visual_id != &"warrior_armor")
	elif event.keycode == KEY_ESCAPE: get_tree().quit()

func _review_combo(skill_level: int, ticket: int) -> void:
	var runtime := BasicAttackComboState.new()
	runtime.set_skill_level(skill_level)
	if skill_level > 0: runtime.set_enabled(true)
	var combo := runtime.definition()
	while ticket == _review_generation:
		for motion: Tween in _preview_advances: motion.kill()
		_preview_advances.clear()
		for index: int in _feel_actors.size():
			_feel_actors[index].position = Vector3(.9 if index == 1 else -.9,0,0)
			_feel_actors[index].rotation.y = 0
			avatars[index].blend_facing(0)
		_review_dog.set_hit_lock(0,0)
		if _review_humanoid != null: _review_humanoid.set_hit_lock(0,0)
		for view: WarriorVisual3D in avatars: view.set_locomotion(false)
		for i: int in (1 if _review_single else combo.steps.size()):
			if ticket != _review_generation: return
			var swing := runtime.take_step(Time.get_ticks_msec(),i > 0)
			var step: BasicAttackStepDefinition = swing.step
			var timing := step.scaled_timing(_review_ratio)
			_review_label.text = ("Warrior target | " if _humanoid_target else "Dog target | ")+"%s | step %d/%d | %s | impact %d ms / recovery %d ms / blend %.2f" % [combo.combo_key,i+1,combo.steps.size(),step.animation_key,int(timing.impact),int(timing.end),avatars[0].attack_blend_seconds]
			_review_label.text += " | AS %d | blend %.2f" % [int(_review_ratio*100),avatars[0].attack_blend_seconds]
			for overlay: CombatTraceDebug3D in _trace_overlays: overlay.queue_free()
			_trace_overlays.clear()
			if OS.get_cmdline_user_args().has("--trace-review"):
				for view: WarriorVisual3D in avatars:
					var overlay := CombatTraceDebug3D.new()
					add_child(overlay)
					overlay.transform = view.transform
					var targets: Array[Dictionary] = []
					var feet := overlay.to_local(_review_dog.global_position)
					var radius := .35 if _humanoid_target else .4
					var height := 1.8 if _humanoid_target else .8
					var hit := CombatTraceResolver.hits_capsule(step.combat_trace,view.transform,_review_dog.position,radius,height)
					targets.append({"id":1,"position":feet,"radius":radius,"height":height,"hit":hit,"predicted":true})
					var pack_count := 0
					for argument: String in OS.get_cmdline_user_args():
						if argument.begins_with("--trace-pack="): pack_count = clampi(argument.get_slice("=",1).to_int(),0,100)
					var measured_at := Time.get_ticks_usec()
					var pack_hits := 0
					for target_index: int in pack_count:
						var pack_feet := Vector3((target_index%10-5)*.35,0,-.6-(target_index/10)*.3)
						var pack_hit := CombatTraceResolver.hits_capsule(step.combat_trace,Transform3D.IDENTITY,pack_feet,.4,.8)
						if pack_hit: pack_hits += 1
						targets.append({"id":target_index+2,"position":pack_feet,"radius":.4,"height":.8,"hit":pack_hit,"predicted":true})
					if pack_count > 0: print("TRACE_PREVIEW tests=",pack_count," hits=",pack_hits," usec=",Time.get_ticks_usec()-measured_at)
					overlay.configure(step,targets,_legacy_trace)
					_trace_overlays.append(overlay)
			for index: int in avatars.size():
				var view := avatars[index]
				if not _feel_actors.is_empty():
					var actor := _feel_actors[index]
					var visible_yaw := actor.rotation.y+view.rotation.y
					actor.rotation.y = PI/2 if _review_turn and i%2 == 1 else 0.0
					view.blend_facing(wrapf(visible_yaw-actor.rotation.y,-PI,PI))
					var direction := Vector3(-sin(actor.rotation.y),0,-cos(actor.rotation.y))
					if index < _preview_advances.size(): _preview_advances[index].kill()
					var motion := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
					motion.tween_property(actor,"position",actor.position+direction*step.advance_distance,float(timing.motion)/1000.0)
					if index < _preview_advances.size(): _preview_advances[index] = motion
					else: _preview_advances.append(motion)
				view.play_basic_attack(step.animation_key,int(timing.motion),_review_ratio)
			await get_tree().create_timer(float(timing.impact)/1000.0).timeout
			if ticket != _review_generation: return
			var result := HitReactionResolver.resolve(step,HitReactionProfiles.NORMAL,1,100,false)
			var contact := _trace_overlays.is_empty()
			for overlay: CombatTraceDebug3D in _trace_overlays: contact = contact or overlay.targets[0].hit
			if contact:
				if _humanoid_target:
					if result.reaction == HitReaction.Type.KNOCKDOWN: _review_humanoid.set_hit_lock(result.duration,result.get_up_duration)
					else: _review_humanoid.play_hit()
				else:
					if result.reaction == HitReaction.Type.KNOCKDOWN: _review_dog.set_hit_lock(result.duration,result.get_up_duration)
					else: _review_dog.play_hit()
			if _feel_feedback != null: _show_feel_hits(step,ticket*100+i,bool(swing.finisher))
			if OS.get_cmdline_user_args().has("--action-capture") or OS.get_cmdline_user_args().has("--feel-capture") or OS.get_cmdline_user_args().has("--combo-capture") or OS.get_cmdline_user_args().has("--vertical-capture"):
				await RenderingServer.frame_post_draw
				assert(get_viewport().get_texture().get_image().save_png("res://.godot/verification/%s-%d-step-%d.png" % [_capture_prefix(),combo.steps.size(),i+1]) == OK)
			await get_tree().create_timer((float(timing.motion if _review_single else timing.end)-float(timing.impact))/1000.0).timeout
		_review_label.text = "%s complete; idle / recovery" % combo.combo_key
		await get_tree().create_timer(1.8).timeout
		if OS.get_cmdline_user_args().has("--action-capture") or OS.get_cmdline_user_args().has("--feel-capture") or OS.get_cmdline_user_args().has("--combo-capture") or OS.get_cmdline_user_args().has("--vertical-capture"):
			await RenderingServer.frame_post_draw
			assert(get_viewport().get_texture().get_image().save_png("res://.godot/verification/%s-%d-idle.png" % [_capture_prefix(),combo.steps.size()]) == OK)
			return
		runtime.reset()

func _set_review_target(humanoid: bool) -> void:
	_humanoid_target = humanoid
	_review_dog.visible = not humanoid
	_review_humanoid.visible = humanoid

func _capture_prefix() -> String:
	if OS.get_cmdline_user_args().has("--action-capture"): return "action-single%d-turn%d" % [int(_review_single),int(_review_turn)]
	if OS.get_cmdline_user_args().has("--feel-capture"): return "feel-as%d-blend%d" % [int(_review_ratio*100),int(avatars[0].attack_blend_seconds*1000)]
	if OS.get_cmdline_user_args().has("--vertical-capture"): return "vertical-warrior" if _humanoid_target else "vertical-dog"
	return "combo"

func _setup_feel_pack() -> void:
	_feel_feedback = CombatFeedback3D.new()
	add_child(_feel_feedback)
	_review_dog.visible = false
	for view: WarriorVisual3D in avatars:
		var actor := Node3D.new()
		actor.position = view.position
		add_child(actor)
		view.reparent(actor,false)
		view.position = Vector3.ZERO
		_feel_actors.append(actor)
	var count := 20
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--feel-pack="): count = clampi(arg.get_slice("=",1).to_int(),1,50)
	for i: int in count:
		var dog := MobActor3D.new()
		dog.setup_mob(1000+i,Vector3(.9+(i%5-2)*.35,0,-1.2-(i/5)*.4))
		dog.ai_enabled = false
		add_child(dog)
		_feel_targets.append(dog)

func _show_feel_hits(step: BasicAttackStepDefinition, action_id: int, finisher: bool) -> void:
	var count := 0
	var started := Time.get_ticks_usec()
	for dog: MobActor3D in _feel_targets:
		if not CombatTraceResolver.hits_capsule(step.combat_trace,_feel_actors[1].transform,dog.position,dog.combat_radius(),dog.combat_height(),dog.combat_bottom_offset()): continue
		var result := HitReactionResolver.resolve(step,HitReactionProfiles.NORMAL,13,120,false)
		var event := result.presentation()
		event.merge({"attacker":1,"action_id":action_id,"target_kind":"mob","target_id":dog.mob_id,"finisher":finisher})
		_feel_feedback.confirm(event,dog,true)
		if _preview_camera != null: _preview_camera.confirm_finisher(event,true)
		if result.reaction == HitReaction.Type.KNOCKDOWN: dog.present_hit_lock(int(result.duration*1000),int(result.get_up_duration*1000))
		else: dog.play_hit()
		dog.hp = 120-result.damage
		dog._update_hp_bar()
		count += 1
	print("FEEL_PREVIEW AS=",int(_review_ratio*100)," clip=",step.animation_key," pack=",_feel_targets.size()," hits=",count," feedback_usec=",Time.get_ticks_usec()-started)

func _process(delta: float) -> void:
	if _preview_camera != null: _preview_camera._tick_impulse(delta)
