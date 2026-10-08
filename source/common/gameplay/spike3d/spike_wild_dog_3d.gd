class_name SpikeWildDog3D
extends SpikeCharacter3D
## Visuals resolve independently. AI, navigation, hit stun and knockback run only
## on the server; clients interpolate position and play presentation effects.

const MAX_HP: int = 120
var mob_id: int
var ai_enabled: bool = true
var home: Vector3
var hp: int = MAX_HP
var ai_state: String = "IDLE"
var target_peer: int = 0
var dead_until_ms: int = 0
var contributions: Dictionary[int, int] = {}
var contribution_players: Dictionary[int, PlayerResource] = {}
var last_attack_ms: int = -1000
var stunned_until_ms: int = 0
var knockback: Vector3 = Vector3.ZERO
var agent: NavigationAgent3D
var hp_label: Label3D
var name_label: Label3D
var _repath_ms: int = 0
var presentation: DogVisual3D

func setup_dog(id: int, spawn: Vector3) -> void:
	mob_id = id
	home = spawn
	position = spawn
	collision_layer = 4
	collision_mask = 1
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 0.8
	collision.shape = shape
	collision.position.y = 0.4
	add_child(collision)
	presentation = DogVisual3D.new()
	presentation.visual_id = &"stray_dog"
	add_child(presentation)
	name_label = _label("Wild Dog", 1.3, 32)
	hp_label = _label("120 / 120", 1.65, 24)
	if GameMode.is_world_server():
		agent = NavigationAgent3D.new()
		agent.path_desired_distance = 0.25
		agent.target_desired_distance = 0.15
		agent.path_max_distance = 1.2
		add_child(agent)

func _label(text: String, height: float, size: int) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position.y = height
	label.font_size = size
	label.pixel_size = 0.012
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	add_child(label)
	return label

func navigate(destination: Vector3, now: int) -> Vector2:
	if agent == null or NavigationServer3D.map_get_iteration_id(get_world_3d().navigation_map) == 0:
		return Vector2.ZERO
	if now >= _repath_ms:
		agent.target_position = destination
		_repath_ms = now + 200
	var next: Vector3 = agent.get_next_path_position()
	if agent.is_navigation_finished(): return Vector2.ZERO
	var offset: Vector3 = next - global_position
	return Vector2(offset.x, offset.z).normalized()

func move_dog(delta: float, direction: Vector2, now: int) -> void:
	if now < stunned_until_ms: direction = Vector2.ZERO
	velocity.x = direction.x * 2.8 + knockback.x
	velocity.z = direction.y * 2.8 + knockback.z
	velocity.y = -0.5 if is_on_floor() else velocity.y - GRAVITY * delta
	knockback *= exp(-5.0 * delta)
	if knockback.length_squared() < 0.01: knockback = Vector3.ZERO
	if direction.length_squared() > 0.001: rotation.y = atan2(-direction.x, -direction.y)
	move_and_slide()

func die(now: int) -> void:
	ai_state = "DEAD"
	target_peer = 0
	dead_until_ms = now + 6000
	knockback = Vector3.ZERO
	visible = false
	collision_layer = 0

func respawn() -> void:
	position = home
	velocity = Vector3.ZERO
	hp = MAX_HP
	contributions.clear()
	contribution_players.clear()
	ai_state = "IDLE"
	target_peer = 0
	stunned_until_ms = 0
	knockback = Vector3.ZERO
	_repath_ms = 0
	visible = true
	collision_layer = 4

func present_snapshot(snapshot: Dictionary) -> void:
	var previous_state := ai_state
	hp = int(snapshot.hp)
	ai_state = str(snapshot.state)
	var active := ai_state not in ["DEAD", "DISABLED"]
	# The corpse is presentation only. Collision disables immediately as before.
	visible = ai_state != "DISABLED"
	collision_layer = 4 if active else 0
	name_label.visible = active
	hp_label.visible = active
	if ai_state == "DEAD" and previous_state != "DEAD": presentation.play_death()
	elif active and previous_state in ["DEAD", "DISABLED"]: presentation.reset_alive()
	apply_snapshot(snapshot.position, snapshot.yaw)
	hp_label.text = "%d / %d" % [hp, MAX_HP]

func interpolate(delta: float) -> void:
	var previous_position := position
	super.interpolate(delta)
	var moving := Vector2(position.x - previous_position.x, position.z - previous_position.z).length() > delta * 0.1
	presentation.set_locomotion(ai_state, moving)

func play_hit() -> void:
	presentation.play_hit()

func mark_selected(selected: bool) -> void:
	name_label.modulate = Color("ffe291") if selected else Color.WHITE
