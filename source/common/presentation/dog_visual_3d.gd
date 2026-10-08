class_name DogVisual3D
extends Node3D
## Presentation only. Clip time never drives movement, hits, death or respawn.
const DEATH_DISPLAY_SECONDS := 1.0
var visual_id: StringName = VisualResolver.STRAY_DOG
var content: Node3D
var player: AnimationPlayer
var animation_state: StringName = &"idle"
var _locomotion: StringName = &"idle"
var _one_shot: StringName = &""
var _remaining: float = 0.0
var _flash: Tween
var _base_scale: Vector3 = Vector3.ONE
var _base_rotation: Vector3 = Vector3.ZERO
var _selected_scene: String = ""
var _refresh_accum: float = 0.0

func _ready() -> void:
	reload_visual()

func reload_visual() -> void:
	var old_shot := _one_shot
	var old_remaining := _remaining
	var old_visible := visible
	if _flash != null: _flash.kill()
	if content != null: content.free()
	content = null
	player = null
	var scene := VisualResolver.resolve(visual_id)
	if scene == null: return
	_selected_scene = scene.resource_path
	content = scene.instantiate() as Node3D
	_base_scale = content.scale
	_base_rotation = content.rotation
	add_child(content)
	var players := content.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		player = players[0] as AnimationPlayer
		_prepare_animations()
	_one_shot = &""
	_remaining = 0.0
	visible = true
	animation_state = &""
	_play(_locomotion)
	if old_shot != &"":
		if old_shot == &"death": play_death()
		else: play_hit()
		_remaining = old_remaining
		visible = old_visible
		if player != null and player.has_animation(old_shot):
			player.seek(clampf(player.get_animation(old_shot).length - old_remaining, 0.0, player.get_animation(old_shot).length), true)

func _prepare_animations() -> void:
	# Copies prevent mutation of cached resources and other dogs' clips.
	for library_name: StringName in player.get_animation_library_list():
		var source_library := player.get_animation_library(library_name)
		var library := AnimationLibrary.new()
		for clip_name: StringName in source_library.get_animation_list():
			var clip := source_library.get_animation(clip_name).duplicate() as Animation
			clip.loop_mode = Animation.LOOP_LINEAR if clip_name in [&"idle", &"run", &"attack"] else Animation.LOOP_NONE
			# Preserve vertical bob and rotation; remove planar root displacement.
			for track: int in clip.get_track_count():
				if clip.track_get_type(track) != Animation.TYPE_POSITION_3D: continue
				var path := clip.track_get_path(track)
				var target := player.get_node(player.root_node).get_node_or_null(NodePath(path.get_concatenated_names()))
				if not target is Skeleton3D or path.get_subname_count() == 0: continue
				var skeleton := target as Skeleton3D
				var bone := skeleton.find_bone(path.get_subname(0))
				if bone < 0 or skeleton.get_bone_parent(bone) != -1: continue
				if clip.track_get_key_count(track) == 0: continue
				var origin: Vector3 = clip.track_get_key_value(track, 0)
				for key: int in clip.track_get_key_count(track):
					var position: Vector3 = clip.track_get_key_value(track, key)
					position.x = origin.x
					position.z = origin.z
					clip.track_set_key_value(track, key, position)
			library.add_animation(clip_name, clip)
		player.remove_animation_library(library_name)
		player.add_animation_library(library_name, library)

func set_locomotion(state: String, moving: bool) -> void:
	_locomotion = &"attack" if state == "ATTACK" else (&"run" if moving else &"idle")
	if _one_shot == &"": _play(_locomotion)

func play_hit() -> void:
	if _one_shot == &"death": return
	_one_shot = &"hit"
	_remaining = 0.2
	if player != null and player.has_animation(&"hit"):
		_remaining = player.get_animation(&"hit").length
	_play(&"hit", true)
	if content == null: return
	if _flash != null: _flash.kill()
	content.scale = _base_scale * 1.06
	_flash = create_tween()
	_flash.tween_property(content, "scale", _base_scale, 0.18)

func play_death() -> void:
	_one_shot = &"death"
	_remaining = DEATH_DISPLAY_SECONDS
	visible = true
	_play(&"death", true)
	if player == null and content != null: content.rotation.z = _base_rotation.z + PI * 0.5

func reset_alive() -> void:
	_one_shot = &""
	_remaining = 0.0
	visible = true
	if content != null: content.rotation = _base_rotation
	_play(_locomotion, true)

func _play(state: StringName, restart: bool = false) -> void:
	if animation_state == state and not restart: return
	animation_state = state
	if player != null and player.has_animation(state): player.play(state, 0.08)

func _process(delta: float) -> void:
	if VisualResolver.local_development_enabled():
		_refresh_accum += delta
		if _refresh_accum >= 0.25:
			_refresh_accum = 0.0
			var scene := VisualResolver.resolve(visual_id)
			if scene != null and scene.resource_path != _selected_scene: reload_visual()
	if _one_shot == &"": return
	_remaining -= delta
	if _remaining > 0: return
	if _one_shot == &"death":
		visible = false
		return
	_one_shot = &""
	_play(_locomotion)
