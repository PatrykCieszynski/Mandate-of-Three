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
# Keep the PackedScene alive while its instances are in use; loader cache is weak.
var _scene_resource: PackedScene
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
	_scene_resource = scene
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
	VisualAnimationTools.prepare_in_place(player, [&"idle", &"run", &"attack"])

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
