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
var _swing_yaw := 0.0
var _swing_until_ms := 0
var _advance_yaw := 0.0
var _advance_distance := 0.0
var _advance_duration := 0.0
var _advance_elapsed := 0.0
var combat_collider: CollisionShape3D

func setup(display_name: String, tint: Color) -> void:
	_display_name = display_name
	collision_layer = 2
	collision_mask = 1 | 4 # Scenery + mob movement BODY; mobs do not mask players.
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	var shape := CollisionShape3D.new()
	combat_collider = shape
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
		label.font_size = 22
		label.pixel_size = 0.006
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		add_child(label)

func set_level(level: int) -> void:
	if _name_label != null: _name_label.text = "Lv %d · %s" % [level, _display_name]

func simulate(delta: float, direction: Vector2) -> void:
	# Never run collision recovery on a corpse: moving mob BODYs could push it.
	if not alive:
		velocity = Vector3.ZERO
		return
	if hit_reaction.locked(Time.get_ticks_msec()) or knockback_active():
		direction = Vector2.ZERO
		cancel_attack_advance()
	var displacement_velocity := damp_knockback(delta) + _consume_attack_advance(delta)
	velocity.x = direction.x * SPEED + displacement_velocity.x
	velocity.z = direction.y * SPEED + displacement_velocity.z
	velocity.y = -0.5 if is_on_floor() else velocity.y - GRAVITY * delta
	if direction.length_squared() > 0.001:
		rotation.y = atan2(-direction.x, -direction.y)
	move_and_slide()

func start_attack_advance(yaw: float, distance: float, duration: float) -> void:
	_advance_yaw = yaw
	_advance_distance = maxf(0,distance)
	_advance_duration = maxf(.001,duration)
	_advance_elapsed = 0.0

func cancel_attack_advance() -> void:
	_advance_distance = 0.0
	_advance_elapsed = _advance_duration

func _consume_attack_advance(delta: float) -> Vector3:
	if delta <= 0 or _advance_distance <= 0 or _advance_elapsed >= _advance_duration: return Vector3.ZERO
	var previous := clampf(_advance_elapsed/_advance_duration,0,1)
	_advance_elapsed = minf(_advance_elapsed+delta,_advance_duration)
	var next := _advance_elapsed/_advance_duration
	# Integrate smoothstep exactly across the tick; speed changes time, not distance.
	var travel := _advance_distance*(next*next*(3-2*next)-previous*previous*(3-2*previous))
	return Vector3(-sin(_advance_yaw),0,-cos(_advance_yaw))*travel/delta

func accept_swing_facing(yaw: float) -> void:
	var visible_yaw := rotation.y + (player_presentation.rotation.y if player_presentation != null else 0.0)
	rotation.y = yaw
	target_yaw = yaw
	if player_presentation != null: player_presentation.blend_facing(wrapf(visible_yaw-yaw,-PI,PI))

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
	rotation.y = _swing_yaw if Time.get_ticks_msec() < _swing_until_ms else lerp_angle(rotation.y,target_yaw,weight)
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
	if not alive:
		_swing_until_ms = 0
		velocity = Vector3.ZERO
		knockback_velocity = Vector3.ZERO
		cancel_attack_advance()
	if player_presentation != null: player_presentation.set_alive(value)

func play_swing(animation_key: StringName, recovery_ms: int, _finisher: bool = false, ratio: float = 1.0) -> void:
	_swing_yaw = rotation.y
	_swing_until_ms = Time.get_ticks_msec()+recovery_ms
	if player_presentation != null: player_presentation.play_basic_attack(animation_key,recovery_ms,ratio)

func get_display_name() -> String:
	return _display_name

func present_hit_lock(down_ms: int, get_up_ms: int) -> void:
	if player_presentation != null and alive:
		player_presentation.set_hit_lock(down_ms/1000.0,get_up_ms/1000.0)

func combat_radius() -> float: return (combat_collider.shape as CapsuleShape3D).radius
func combat_height() -> float: return (combat_collider.shape as CapsuleShape3D).height
func combat_bottom_offset() -> float: return combat_collider.position.y-combat_height()/2.0
