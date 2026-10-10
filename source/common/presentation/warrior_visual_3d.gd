class_name WarriorVisual3D
extends Node3D
## One optional player visual, one variant and one rigid sword. Presentation only.
const SWORD_GRIP_ROTATION_RADIANS := PI * 0.5
var visual_id: StringName = &"warrior"
var tint: Color = Color.WHITE
var content: Node3D
var player: AnimationPlayer
var skeleton: Skeleton3D
var weapon: Node3D
var socket: Node3D
var equipped: bool = false
var alive: bool = true
var animation_state: StringName = &"idle"
var _locomotion: StringName = &"idle"
var _remaining: float = 0.0
var _shot: StringName = &""
var _scene_path: String = ""
var _weapon_path: String = ""
# Retain active scenes so development polling can reuse ResourceLoader cache.
var _scene_resource: PackedScene
var _weapon_resource: PackedScene
var _refresh: float = 0.0
var _flash: Tween
var _swing: Tween

func _ready() -> void:
	reload_visual()

func set_variant(armored: bool) -> void:
	var next_id: StringName = &"warrior_armor" if armored else &"warrior"
	if visual_id == next_id: return
	visual_id = next_id
	if is_node_ready(): reload_visual()

func reload_visual() -> void:
	var previous_shot := _shot
	var previous_remaining := _remaining
	if _flash != null: _flash.kill()
	if _swing != null: _swing.kill()
	if content != null: content.free()
	weapon = null
	socket = null
	player = null
	skeleton = null
	var scene := VisualResolver.resolve(visual_id)
	if scene == null: return
	_scene_resource = scene
	_scene_path = scene.resource_path
	content = scene.instantiate() as Node3D
	add_child(content)
	if content.has_method("set_tint"): content.call("set_tint",tint)
	var players := content.find_children("*","AnimationPlayer",true,false)
	if not players.is_empty():
		player = players[0] as AnimationPlayer
		VisualAnimationTools.prepare_in_place(player,[&"idle",&"run"])
		VisualAnimationTools.align_locomotion_heading(player,[&"idle",&"run"],&"run")
	var skeletons := content.find_children("*","Skeleton3D",true,false)
	if not skeletons.is_empty(): skeleton = skeletons[0] as Skeleton3D
	_attach_weapon()
	_shot = &""
	_remaining = 0.0
	animation_state = &""
	if not alive:
		play_death()
		if player != null and player.has_animation(&"death"): player.seek(player.get_animation(&"death").length,true)
	elif previous_shot != &"":
		_shot = previous_shot
		_remaining = previous_remaining
		_play(previous_shot,true)
		if player != null and player.has_animation(previous_shot):
			player.seek(clampf(player.get_animation(previous_shot).length - previous_remaining,0.0,player.get_animation(previous_shot).length),true)
	else:
		_play(_locomotion,true)

func _attach_weapon() -> void:
	if _swing != null: _swing.kill()
	if socket != null: socket.free()
	socket = null
	weapon = null
	_weapon_path = ""
	_weapon_resource = null
	if not equipped or content == null: return
	if skeleton != null and skeleton.find_bone("equip_right_hand") >= 0:
		var attachment := BoneAttachment3D.new()
		attachment.name = "SwordSocket"
		skeleton.add_child(attachment)
		attachment.bone_name = "equip_right_hand"
		socket = attachment
	else:
		socket = Node3D.new()
		socket.position = Vector3(0.55,0.9,-0.15)
		content.add_child(socket)
	var scene := VisualResolver.resolve(&"iron_sword")
	_weapon_resource = scene
	_weapon_path = scene.resource_path
	weapon = scene.instantiate() as Node3D
	socket.add_child(weapon)
	if socket is BoneAttachment3D:
		# Native rig is centimetres with a 0.01 skeleton scale; sword GLB is metres.
		var parent_scale := skeleton.global_basis.get_scale()
		weapon.scale = Vector3.ONE / parent_scale
		# Shared grip correction for swords authored with the blade along local +Y.
		weapon.rotate_object_local(Vector3.BACK, SWORD_GRIP_ROTATION_RADIANS)
	weapon.visible = alive

func set_equipped(value: bool) -> void:
	if equipped == value: return
	equipped = value
	if is_node_ready(): _attach_weapon()

func set_locomotion(moving: bool) -> void:
	_locomotion = &"run" if moving else &"idle"
	if alive and _shot == &"": _play(_locomotion)

func play_attack(stage: int) -> void:
	if not alive: return
	_one_shot(StringName("attack_%d" % clampi(stage,1,3)),0.3)
	if player == null and weapon != null:
		if _swing != null: _swing.kill()
		weapon.rotation.z = -1.4 if stage != 2 else 1.4
		_swing = create_tween()
		_swing.tween_property(weapon,"rotation:z",1.4 if stage != 2 else -1.4,0.18)
		_swing.tween_property(weapon,"rotation:z",0.0,0.12)

func play_hit() -> void:
	if not alive: return
	_one_shot(&"hit",0.18)
	if content == null: return
	if _flash != null: _flash.kill()
	content.scale = Vector3.ONE * 1.04
	_flash = create_tween()
	_flash.tween_property(content,"scale",Vector3.ONE,0.18)

func set_alive(value: bool) -> void:
	if alive == value: return
	alive = value
	if content == null: return
	if not alive:
		play_death()
	else:
		_shot = &""
		_remaining = 0.0
		content.rotation = Vector3.ZERO
		content.position = Vector3.ZERO
		if weapon != null: weapon.visible = true
		_play(_locomotion,true)

func play_death() -> void:
	_shot = &"death"
	_remaining = 0.0
	_play(&"death",true)
	if player == null:
		content.rotation.z = PI * 0.5
		content.position = Vector3(0.9,0.4,0)
	if weapon != null: weapon.visible = false

func _one_shot(clip: StringName, fallback_duration: float) -> void:
	_shot = clip
	_remaining = player.get_animation(clip).length if player != null and player.has_animation(clip) else fallback_duration
	_play(clip,true)

func _play(clip: StringName, restart: bool = false) -> void:
	if animation_state == clip and not restart: return
	animation_state = clip
	if player != null and player.has_animation(clip): player.play(clip,0.08)

func _process(delta: float) -> void:
	if VisualResolver.local_development_enabled():
		_refresh += delta
		if _refresh >= 0.25:
			_refresh = 0.0
			var scene := VisualResolver.resolve(visual_id)
			var sword_scene := VisualResolver.resolve(&"iron_sword") if equipped else null
			if scene != null and scene.resource_path != _scene_path: reload_visual()
			elif sword_scene != null and sword_scene.resource_path != _weapon_path: _attach_weapon()
	if not alive or _shot == &"": return
	_remaining -= delta
	if _remaining <= 0.0:
		_shot = &""
		_play(_locomotion)
