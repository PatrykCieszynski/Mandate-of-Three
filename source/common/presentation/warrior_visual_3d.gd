class_name WarriorVisual3D
extends Node3D
## One optional player visual, one variant and one rigid sword. Presentation only.
const SWORD_GRIP_ROTATION_RADIANS := PI * 0.5
@export_range(0.0,0.15,0.01) var attack_blend_seconds: float = 0.08
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
var _knockdown := KnockdownVisual.new()
var _locomotion: StringName = &"idle"
var _remaining: float = 0.0
var _shot: StringName = &""
var _basic_attack: bool = false
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
	var previous_attack := _basic_attack
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
	_knockdown.rebind()
	if content.has_method("set_tint"): content.call("set_tint",tint)
	var players := content.find_children("*","AnimationPlayer",true,false)
	if not players.is_empty():
		player = players[0] as AnimationPlayer
	var skeletons := content.find_children("*","Skeleton3D",true,false)
	if not skeletons.is_empty(): skeleton = skeletons[0] as Skeleton3D
	_install_local_motions()
	if player != null:
		VisualAnimationTools.prepare_in_place(player,[&"idle",&"run"])
		VisualAnimationTools.align_locomotion_heading(player,[&"idle",&"run"],&"run")
		validate_combo_animations()
	_attach_weapon()
	_basic_attack = false
	_shot = &""
	_remaining = 0.0
	animation_state = &""
	if not alive:
		play_death()
		if player != null and player.has_animation(&"death"): player.seek(player.get_animation(&"death").length,true)
	elif previous_shot != &"":
		_basic_attack = previous_attack
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
	if alive and _shot == &"" and not _knockdown.active(): _play(_locomotion)

func play_basic_attack(animation_key: StringName, recovery_ms: int) -> void:
	if not alive or _knockdown.active(): return
	if player != null and not player.has_animation(animation_key):
		push_warning("Warrior missing required combo animation: %s (%s)" % [animation_key,_scene_path])
		return
	_one_shot(animation_key,recovery_ms/1000.0,attack_blend_seconds)
	_basic_attack = true
	# Native clip speed stays 1.0. A successor can crossfade at the server's
	# link/recovery time before this clip's full duration has elapsed.
	if player == null and weapon != null:
		if _swing != null: _swing.kill()
		weapon.rotation.z = -1.4
		_swing = create_tween()
		_swing.tween_property(weapon,"rotation:z",1.4,0.18)
		_swing.tween_property(weapon,"rotation:z",0.0,0.12)

func validate_combo_animations() -> bool:
	if player == null: return true # Tracked procedural placeholder has no rig.
	var complete := true
	for key: StringName in BasicAttackCombos.animation_keys():
		if not player.has_animation(key):
			complete = false
			push_warning("Warrior missing required combo animation: %s (%s)" % [key,_scene_path])
	return complete

func _install_local_motions() -> void:
	# Optional reference animations are presentation-only, never loaded by World.
	# The armor GLB has the same native bone names, but a different node prefix.
	if player == null or skeleton == null or not _scene_path.begins_with("res://dev_assets/"): return
	var path := "res://dev_assets/legacy/players/warrior/warrior_all_motions.glb"
	if not VisualResolver.local_development_enabled() or not FileAccess.file_exists(path) or not ResourceLoader.exists(path): return
	var donor := (load(path) as PackedScene).instantiate()
	var source: AnimationPlayer = donor.find_children("*","AnimationPlayer",true,false)[0]
	var library := AnimationLibrary.new()
	var aliases := {&"idle":&"onehand_sword__wait",&"run":&"onehand_sword__run",&"hit":&"onehand_sword__damage",&"death":&"general__dead"}
	var keys := BasicAttackCombos.animation_keys()
	for i: int in range(1,8): keys.append(StringName("twohand_sword__combo_%02d" % i))
	keys.append_array(aliases.keys())
	var target_path := player.get_node(player.root_node).get_path_to(skeleton)
	for key: StringName in keys:
		var source_key: StringName = aliases.get(key,key)
		if not source.has_animation(source_key): continue
		var clip := source.get_animation(source_key).duplicate() as Animation
		for track: int in clip.get_track_count():
			var old_path := clip.track_get_path(track)
			if old_path.get_subname_count() > 0:
				clip.track_set_path(track,NodePath(str(target_path)+":"+old_path.get_concatenated_subnames()))
		library.add_animation(key,clip)
	for name: StringName in player.get_animation_library_list(): player.remove_animation_library(name)
	player.add_animation_library(&"",library)
	donor.free()

func play_hit() -> void:
	if not alive or _knockdown.active(): return
	# Preserve an ongoing swing visually as well as on the server.
	if not _basic_attack: _one_shot(&"hit",0.18)
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
		_basic_attack = false
		_shot = &""
		_remaining = 0.0
		content.rotation = Vector3.ZERO
		content.position = Vector3.ZERO
		if weapon != null: weapon.visible = true
		_play(_locomotion,true)

func play_death() -> void:
	_basic_attack = false
	_knockdown.clear(content)
	_shot = &"death"
	_remaining = 0.0
	_play(&"death",true)
	if player == null:
		content.rotation.z = PI * 0.5
		content.position = Vector3(0.9,0.4,0)
	if weapon != null: weapon.visible = false

func _one_shot(clip: StringName, fallback_duration: float, blend_seconds: float = 0.08) -> void:
	_basic_attack = false
	_shot = clip
	_remaining = player.get_animation(clip).length if player != null and player.has_animation(clip) else fallback_duration
	_play(clip,true,blend_seconds)

func _play(clip: StringName, restart: bool = false, blend_seconds: float = 0.08) -> void:
	if animation_state == clip and not restart: return
	animation_state = clip
	if player != null and player.has_animation(clip):
		player.speed_scale = 1.0
		player.play(clip,blend_seconds)

func _process(delta: float) -> void:
	if VisualResolver.local_development_enabled():
		_refresh += delta
		if _refresh >= 0.25:
			_refresh = 0.0
			var scene := VisualResolver.resolve(visual_id)
			var sword_scene := VisualResolver.resolve(&"iron_sword") if equipped else null
			if scene != null and scene.resource_path != _scene_path: reload_visual()
			elif sword_scene != null and sword_scene.resource_path != _weapon_path: _attach_weapon()
	if not alive: return
	var was_locked := _knockdown.phase != HitReaction.Phase.NONE
	if _knockdown.update(delta,content,player):
		animation_state = &"knockdown" if _knockdown.phase == HitReaction.Phase.DOWN else &"get_up"
		return
	if was_locked: _play(_locomotion,true)
	if _shot == &"": return
	_remaining -= delta
	if _remaining <= 0.0:
		_basic_attack = false
		_shot = &""
		_play(_locomotion)

func set_hit_lock(down: float, get_up: float) -> void:
	if not alive: return
	_knockdown.sync(down,get_up)
	if down > 0 or get_up > 0:
		_basic_attack = false
		_shot = &""
		_remaining = 0
		if _flash != null: _flash.kill()
		if _swing != null: _swing.kill()
		if content != null: content.scale = Vector3.ONE
