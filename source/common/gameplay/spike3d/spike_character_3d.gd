class_name SpikeCharacter3D
extends CharacterBody3D
## The server owns physics; clients interpolate its snapshots.

const SPEED: float = 5.0
const GRAVITY: float = 20.0
const KNOCKBACK_DAMPING: float = 8.0
var knockback_velocity: Vector3 = Vector3.ZERO
var hit_reaction := HitReactionState.new()
var reaction_profile: HitReactionProfile = HitReactionProfiles.PLAYER
var target_position: Vector3
var target_yaw: float = 0.0
var has_snapshot: bool = false
var player_presentation: WarriorVisual3D
var weapon_definition_id: String = ""
var alive: bool = true
var _name_label: Label3D
var _display_name: String = ""

func setup(display_name: String, tint: Color) -> void:
	_display_name = display_name
	collision_layer = 2
	collision_mask = 1
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = 0.9
	add_child(shape)
	if not GameMode.is_world_server():
		player_presentation = WarriorVisual3D.new()
		player_presentation.visual_id = &"warrior"
		player_presentation.tint = tint
		add_child(player_presentation)
		var label := Label3D.new()
		_name_label = label
		label.text = display_name
		label.position.y = 2.25
		label.font_size = 48
		label.pixel_size = 0.012
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		add_child(label)

func set_level(level: int) -> void:
	if _name_label != null: _name_label.text = "Lv %d · %s" % [level, _display_name]

func simulate(delta: float, direction: Vector2) -> void:
	if hit_reaction.locked(Time.get_ticks_msec()) or knockback_active(): direction = Vector2.ZERO
	var displacement_velocity := damp_knockback(delta)
	velocity.x = direction.x * SPEED + displacement_velocity.x
	velocity.z = direction.y * SPEED + displacement_velocity.z
	velocity.y = -0.5 if is_on_floor() else velocity.y - GRAVITY * delta
	if direction.length_squared() > 0.001:
		rotation.y = atan2(-direction.x, -direction.y)
	move_and_slide()

func apply_knockback(direction: Vector3, distance: float) -> void:
	if not direction.is_finite() or not is_finite(distance) or distance <= 0: return
	var planar := Vector3(direction.x,0,direction.z)
	if planar.length_squared() < 0.0001: return
	# Integral of v0 * exp(-damping*t) is distance. No position mutation here.
	knockback_velocity = planar.normalized() * distance * KNOCKBACK_DAMPING

func knockback_active() -> bool:
	return knockback_velocity.length_squared() > 0.0025

func damp_knockback(delta: float) -> Vector3:
	if delta <= 0: return Vector3.ZERO
	var decay := exp(-KNOCKBACK_DAMPING * delta)
	# Average velocity keeps travel independent of physics tick duration.
	var motion := knockback_velocity * (1.0-decay) / (KNOCKBACK_DAMPING*delta)
	knockback_velocity *= decay
	if not knockback_active(): knockback_velocity = Vector3.ZERO
	return motion

func apply_snapshot(next_position: Vector3, yaw: float) -> void:
	if not has_snapshot or position.distance_to(next_position) > 5.0:
		position = next_position
		rotation.y = yaw
	target_position = next_position
	target_yaw = yaw
	has_snapshot = true

func interpolate(delta: float) -> void:
	if not has_snapshot:
		return
	var previous_position := position
	var weight: float = 1.0 - exp(-20.0 * delta)
	position = position.lerp(target_position, weight)
	rotation.y = lerp_angle(rotation.y, target_yaw, weight)
	if player_presentation != null:
		player_presentation.set_locomotion(Vector2(position.x - previous_position.x,position.z - previous_position.z).length() > delta * 0.1)

func set_weapon(definition_id: String) -> void:
	if weapon_definition_id == definition_id: return
	weapon_definition_id = definition_id
	if player_presentation != null:
		player_presentation.set_equipped(ItemDefinitions.get_definition(StringName(definition_id)) != null)

func play_hit() -> void:
	if player_presentation != null: player_presentation.play_hit()

func set_alive(value: bool) -> void:
	if alive == value: return
	alive = value
	if player_presentation != null: player_presentation.set_alive(value)

func play_swing(animation_key: StringName, recovery_ms: int, finisher: bool = false) -> void:
	if player_presentation != null: player_presentation.play_basic_attack(animation_key,recovery_ms)
	# Brief sweeping ribbon; presentation only, never the damage authority.
	var vertices := PackedVector3Array()
	for i: int in 16:
		var first: float = deg_to_rad(-65.0 + i * 130.0 / 16)
		var second: float = deg_to_rad(-65.0 + (i + 1) * 130.0 / 16)
		var a := Vector3(sin(first), 0.65, -cos(first)) * Vector3(1.9, 1, 1.9)
		var b := Vector3(sin(first), 0.65, -cos(first)) * Vector3(2.3, 1, 2.3)
		var c := Vector3(sin(second), 0.65, -cos(second)) * Vector3(2.3, 1, 2.3)
		var d := Vector3(sin(second), 0.65, -cos(second)) * Vector3(1.9, 1, 1.9)
		vertices.append_array(PackedVector3Array([a, b, c, a, c, d]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var slash := MeshInstance3D.new()
	slash.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1, 0.8, 0.25, 0.8) if finisher else Color(0.6, 0.9, 1, 0.6)
	slash.material_override = material
	add_child(slash)
	var tween := create_tween()
	tween.tween_property(material, "albedo_color:a", 0.0, 0.25)
	tween.tween_callback(slash.queue_free)

func get_display_name() -> String:
	return _display_name

func present_hit_lock(down_ms: int, get_up_ms: int) -> void:
	if player_presentation != null and alive:
		player_presentation.set_hit_lock(down_ms/1000.0,get_up_ms/1000.0)

func combat_radius() -> float: return 0.35
func combat_height() -> float: return 1.8
