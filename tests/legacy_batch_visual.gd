extends Node3D
## Optional first-batch probe. No legacy file is needed in default mode.
const IDS: Array[StringName] = [&"stray_dog", &"wolf", &"wild_boar", &"bear", &"tiger", &"barbarian_soldier", &"barbarian_infantry", &"barbarian_bow", &"orc_soldier", &"orc_scouter", &"orc_knight", &"orc_black", &"orc_magician", &"metinstone_01", &"metinstone_02", &"warrior", &"warrior_armor", &"warrior_saja", &"warrior_cheongrin", &"iron_sword", &"sword_00020", &"sword_00030", &"sword_00040"]
var failed := false
var rows: Array[Dictionary] = []
var require_dev := false
var preview := false
var allowed_missing: PackedStringArray = []
var clips: Array[AnimationPlayer] = []
var clip_index := 0
var timer := 0.0

func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)

func nodes(root: Node, kind: String) -> Array[Node]:
	var result: Array[Node] = []
	if root.is_class(kind): result.append(root)
	for child in root.get_children(): result.append_array(nodes(child, kind))
	return result

func _ready() -> void:
	require_dev = OS.get_cmdline_user_args().has("--require-batch-dev")
	preview = OS.get_cmdline_user_args().has("--batch-preview")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--batch-allow-missing="): allowed_missing = arg.trim_prefix("--batch-allow-missing=").split(",")
	for i in IDS.size():
		var id := IDS[i]
		var scene := VisualResolver.resolve(id)
		check(scene != null, "No fallback for %s" % id)
		if scene == null: continue
		var source := scene.resource_path
		var expect_dev := require_dev and not allowed_missing.has(String(id))
		check(source.begins_with("res://dev_assets/") if expect_dev else not source.begins_with("res://dev_assets/"), "Unexpected source %s" % source)
		var first := scene.instantiate() as Node3D
		var second := scene.instantiate() as Node3D
		add_child(first)
		add_child(second)
		first.position = Vector3((i % 6) * 3.5 - 8.75, 0, (i / 6) * 4.0 - 6.0)
		second.position = first.position + Vector3(1.4, 0, 0)
		var meshes := nodes(first, "MeshInstance3D")
		check(not meshes.is_empty(), "No mesh: %s" % id)
		var skeletons := nodes(first, "Skeleton3D")
		var animations := nodes(first, "AnimationPlayer")
		var row := {"id": String(id), "source": source, "meshes": meshes.size(), "bones": 0, "clips": []}
		for mesh_node in meshes:
			var mesh := mesh_node as MeshInstance3D
			check(mesh.mesh != null, "Missing mesh resource: %s" % id)
			for surface in mesh.mesh.get_surface_count():
				var material := mesh.get_active_material(surface) as StandardMaterial3D
				if expect_dev: check(material != null, "Missing material: %s" % id)
				if expect_dev and material != null:
					check(material.albedo_texture != null, "Missing texture: %s" % id)
					if material.albedo_texture != null: check(material.albedo_texture.get_width() > 0, "Invalid texture")
		if expect_dev and not String(id).contains("sword"):
			check(skeletons.size() == 1, "Expected one skeleton: %s" % id)
			check(animations.size() == 1, "Expected one player: %s" % id)
			if not skeletons.is_empty():
				var skeleton := skeletons[0] as Skeleton3D
				row.bones = skeleton.get_bone_count()
				check(row.bones > 1, "Empty skeleton: %s" % id)
			if not animations.is_empty():
				var player := animations[0] as AnimationPlayer
				var other := nodes(second, "AnimationPlayer")[0] as AnimationPlayer
				VisualAnimationTools.prepare_in_place(player, [&"idle", &"walk", &"run"])
				VisualAnimationTools.prepare_in_place(other, [&"idle", &"walk", &"run"])
				for clip_name in player.get_animation_list():
					if clip_name == &"RESET": continue
					var clip := player.get_animation(clip_name)
					check(clip != other.get_animation(clip_name), "Shared mutable clip: %s" % id)
					row.clips.append(String(clip_name))
					check(clip.length > 0, "Zero clip duration: %s/%s" % [id, clip_name])
					for track in clip.get_track_count():
						if clip.track_get_type(track) != Animation.TYPE_POSITION_3D: continue
						var path := clip.track_get_path(track)
						var target := player.get_node(player.root_node).get_node_or_null(NodePath(path.get_concatenated_names())) as Skeleton3D
						if target == null or path.get_subname_count() == 0 or clip.track_get_key_count(track) == 0: continue
						var bone := target.find_bone(path.get_subname(0))
						if bone < 0 or target.get_bone_parent(bone) != -1: continue
						var start: Vector3 = clip.track_get_key_value(track, 0)
						for key in clip.track_get_key_count(track):
							var value: Vector3 = clip.track_get_key_value(track, key)
							check(abs(value.x-start.x) < .0001 and abs(value.z-start.z) < .0001, "Planar root motion: %s" % id)
					var original := first.global_position
					player.play(clip_name)
					player.seek(clip.length * .5, true)
					player.advance(0)
					check(first.global_position.is_equal_approx(original), "Visual moved entity: %s" % id)
				for required in [&"idle", &"run", &"hit", &"death"]: check(player.has_animation(required), "Missing clip %s/%s" % [id, required])
				check(player.has_animation(&"attack") or player.has_animation(&"attack_1"), "Missing attack: %s" % id)
				player.play(&"idle")
				player.seek(0, true)
				player.advance(0)
				other.play(&"run")
				clips.append(player)
				clips.append(other)
		if not preview:
			first.queue_free()
			second.queue_free()
		rows.append(row)
	await get_tree().process_frame
	if preview: setup_preview()
	else: finish()

func finish() -> void:
	var report := FileAccess.open("res://.godot/verification/batch-godot-report.json", FileAccess.WRITE)
	if report != null: report.store_string(JSON.stringify({"success": not failed, "require_dev": require_dev, "rows": rows}, "\t"))
	if not failed: print("LEGACY_BATCH_VISUAL_OK ", rows.size(), " dev=", require_dev)
	get_tree().quit(1 if failed else 0)

func setup_preview() -> void:
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(0, 19, 19)
	camera.look_at(Vector3.ZERO)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 26
	camera.current = true
	var light := DirectionalLight3D.new()
	add_child(light)
	light.rotation_degrees = Vector3(-55, -25, 0)
	light.light_energy = 1.4
	var environment := WorldEnvironment.new()
	add_child(environment)
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(.10, .12, .16)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = .65
	for i in IDS.size():
		var label := Label3D.new()
		add_child(label)
		label.text = String(IDS[i])
		label.position = Vector3((i % 6) * 3.5 - 8.05, 2.4, (i / 6) * 4.0 - 6.0)
		label.font_size = 36
		label.pixel_size = .008
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	if OS.get_cmdline_user_args().has("--batch-capture"):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.godot/verification/legacy-batch-gallery.png")
		finish()

func _process(delta: float) -> void:
	if not preview: return
	timer += delta
	if timer > 3:
		timer = 0
		clip_index += 1
		var states: Array[StringName] = [&"idle", &"run", &"attack", &"hit", &"death"]
		for player in clips:
			var clip := states[clip_index % states.size()]
			if clip == &"attack" and player.has_animation(&"attack_1"): clip = &"attack_1"
			if player.has_animation(clip): player.play(clip)
	if Input.is_key_pressed(KEY_ESCAPE): finish()
