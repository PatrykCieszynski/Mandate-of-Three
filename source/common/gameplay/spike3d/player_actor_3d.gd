class_name PlayerActor3D
extends Actor3D
## The server owns physics; clients interpolate its snapshots.

const SPEED: float = 5.0
var hp: int = 100
var max_hp: int = 100
# Player lifecycle deadline; MobSystem owns pack replacements separately.
var respawn_at_ms: int = 0
var player_presentation: WarriorVisual3D
var weapon_definition_id: String = ""
var _name_label: Label3D
var _display_name: String = ""
var _swing_yaw := 0.0
var _swing_until_ms := 0
var _advance_yaw := 0.0
var _advance_distance := 0.0
var _advance_duration := 0.0
var _advance_elapsed := 0.0

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
	var advance_velocity := _consume_attack_advance(delta)
	var displacement_velocity := damp_knockback(delta) + advance_velocity
	velocity.x = direction.x * SPEED + displacement_velocity.x
	velocity.z = direction.y * SPEED + displacement_velocity.z
	velocity.y = -0.5 if is_on_floor() else velocity.y - GRAVITY * delta
	if direction.length_squared() > 0.001:
		rotation.y = atan2(-direction.x, -direction.y)
	# Mobs can chase into us. Existing penetration must not become an unsolicited
	# recovery impulse; permit departure, but never movement deeper into a BODY.
	var overlaps := _overlapping_mob_bodies()
	var planar := Vector3(velocity.x,0,velocity.z)
	for mob: PhysicsBody3D in overlaps:
		var offset := mob.global_position-global_position
		if planar.dot(Vector3(offset.x,0,offset.z)) > 0.0001:
			velocity.x = 0
			velocity.z = 0
			break
	var temporary_exceptions: Array[PhysicsBody3D] = []
	var existing_exceptions := get_collision_exceptions()
	for mob: PhysicsBody3D in overlaps:
		if existing_exceptions.has(mob): continue
		add_collision_exception_with(mob)
		temporary_exceptions.append(mob)
	if advance_velocity.length_squared() > 0 and delta > 0:
		# Probe the straight advance before the normal slide. Consume the curve
		# even when blocked, but discard the tangential remainder on actor BODY.
		var collision := KinematicCollision3D.new()
		var motion := Vector3(velocity.x,0,velocity.z)*delta
		if test_move(global_transform,motion,collision,safe_margin):
			var collider := collision.get_collider() as PhysicsBody3D
			if collider != null and collider.collision_layer & 4:
				var allowed := maxf(0,collision.get_travel().dot(motion.normalized()))
				var fraction := clampf(allowed/motion.length(),0,1) if motion.length() > 0 else 0.0
				velocity.x *= fraction
				velocity.z *= fraction
	move_and_slide()
	for mob: PhysicsBody3D in temporary_exceptions: remove_collision_exception_with(mob)

func _overlapping_mob_bodies() -> Array[PhysicsBody3D]:
	var overlaps: Array[PhysicsBody3D] = []
	if combat_collider == null or not collision_mask & 4: return overlaps
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = combat_collider.shape
	query.transform = combat_collider.global_transform
	query.collision_mask = 4
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query,256):
		var mob := hit.collider as MobActor3D
		if mob != null and not overlaps.has(mob): overlaps.append(mob)
	return overlaps

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
