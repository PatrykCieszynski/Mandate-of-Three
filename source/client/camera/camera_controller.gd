class_name MandateCamera3D
extends Node3D
## Client-owned orbit/follow rig. World supplies interpolated position; no body writes/RPCs.
signal pointer_capture_changed(active: bool)
@export var settings: MandateCameraSettings = preload("res://source/client/camera/camera_v1.tres")
var camera: Camera3D
var can_control: Callable
var orbiting: bool = false
var desired_distance: float
var resolved_distance: float
var desired_yaw: float
var desired_pitch: float
var _yaw: float
var _pitch: float
var _zoom: float
var _pivot: Vector3
var _previous_target: Vector3
var _initialized: bool = false
var _moving_time: float = 0.0
var _since_manual: float = 0.0
var _previous_pointer: Vector2
var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE
var _sphere := SphereShape3D.new()

func _ready() -> void:
	assert(settings.min_distance > 0 and settings.max_distance >= settings.min_distance)
	assert(settings.min_pitch > -89 and settings.max_pitch < 89 and settings.max_pitch >= settings.min_pitch)
	assert(settings.collision_radius > 0 and settings.collision_margin >= 0)
	desired_distance = clampf(settings.default_distance, settings.min_distance, settings.max_distance)
	desired_yaw = deg_to_rad(settings.default_yaw)
	desired_pitch = clampf(settings.default_pitch, settings.min_pitch, settings.max_pitch)
	_yaw = desired_yaw
	_pitch = desired_pitch
	_zoom = desired_distance
	resolved_distance = desired_distance
	_sphere.radius = settings.collision_radius + settings.collision_margin
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = settings.fov
	camera.near = 0.05
	camera.current = true
	add_child(camera)
	camera.position = Vector3(0, 6, 6)
	camera.look_at(Vector3(0, settings.pivot_height, 0))

func _allowed() -> bool:
	return can_control.is_valid() and bool(can_control.call())

func _unhandled_input(event: InputEvent) -> void:
	if not _allowed(): return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			orbiting = true
			_previous_pointer = event.position
			_previous_mouse_mode = Input.mouse_mode
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			pointer_capture_changed.emit(true)
			get_viewport().set_input_as_handled()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			zoom_by(-event.factor if event.button_index == MOUSE_BUTTON_WHEEL_UP else event.factor)
			get_viewport().set_input_as_handled()

func _input(event: InputEvent) -> void:
	if not orbiting: return
	if not _allowed():
		cancel_orbit()
		return
	if event is InputEventMouseMotion:
		orbit_by(event.relative)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed: cancel_orbit()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			zoom_by(-event.factor if event.button_index == MOUSE_BUTTON_WHEEL_UP else event.factor)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		cancel_orbit()
		get_viewport().set_input_as_handled()

func orbit_by(relative: Vector2) -> void:
	if not relative.is_finite(): return
	desired_yaw = wrapf(desired_yaw - deg_to_rad(relative.x * settings.orbit_sensitivity), -PI, PI)
	desired_pitch = clampf(desired_pitch + relative.y * settings.orbit_sensitivity, settings.min_pitch, settings.max_pitch)
	_since_manual = 0.0
	_moving_time = 0.0

## Convert manual screen-relative input into the same bounded XZ intention.
## Use the rendered camera basis, not its requested yaw; pitch never changes speed.
func movement_direction(input: Vector2) -> Vector2:
	if not input.is_finite(): return Vector2.ZERO
	var right: Vector2 = Vector2(camera.global_basis.x.x, camera.global_basis.x.z).normalized()
	var back: Vector2 = Vector2(camera.global_basis.z.x, camera.global_basis.z.z).normalized()
	return (right * input.x + back * input.y).limit_length()

func zoom_by(steps: float) -> void:
	if not is_finite(steps): return
	desired_distance = clampf(desired_distance + steps * settings.zoom_speed, settings.min_distance, settings.max_distance)
	_since_manual = 0.0

func cancel_orbit() -> void:
	if not orbiting: return
	orbiting = false
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = _previous_mouse_mode
		if DisplayServer.get_name() != "headless" and DisplayServer.window_is_focused(): Input.warp_mouse(_previous_pointer)
	pointer_capture_changed.emit(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT: cancel_orbit()

func _exit_tree() -> void:
	cancel_orbit()

func _weight(rate: float, delta: float) -> float:
	return 1.0 - exp(-maxf(rate, 0.0) * delta)

## Sweep a sphere rather than just the center ray. Test initial overlap explicitly:
## Godot cast_motion ignores bodies overlapping the starting shape.
func _safe_motion(origin: Vector3, motion: Vector3) -> Vector3:
	if motion.length_squared() < 0.000001: return Vector3.ZERO
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _sphere
	query.transform = Transform3D(Basis.IDENTITY, origin)
	query.collision_mask = settings.collision_mask
	# Include clearance in the shape itself so overlap and sweep use one volume.
	query.margin = 0.0
	query.collide_with_areas = false
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if not space.intersect_shape(query, 1).is_empty(): return Vector3.ZERO
	query.motion = motion
	var fractions: PackedFloat32Array = space.cast_motion(query)
	if fractions.size() != 2: return Vector3.ZERO
	if fractions[0] >= 1.0: return motion
	# Keep the resolved pivot outside the next query's overlap tolerance.
	# Ending exactly at the safe fraction can turn an outward boom into a zero cast.
	var length: float = motion.length()
	return motion / length * maxf(0.0, length * fractions[0] - settings.collision_skin)

## Called after character interpolation, not from the authoritative simulation.
func update_camera(delta: float, target: Vector3, controls_enabled: bool) -> void:
	if not target.is_finite() or not is_finite(delta) or delta <= 0: return
	if not controls_enabled: cancel_orbit()
	var snap: bool = not _initialized or target.distance_to(_previous_target) > settings.teleport_distance
	var movement: Vector3 = target - _previous_target if _initialized else Vector3.ZERO
	_since_manual += delta
	_moving_time = _moving_time + delta if Vector2(movement.x, movement.z).length() > delta * 0.1 else 0.0
	if settings.auto_align_enabled and controls_enabled and not orbiting and _moving_time > settings.auto_align_delay and _since_manual > settings.auto_align_delay:
		var behind: float = atan2(-movement.x, -movement.z)
		desired_yaw = lerp_angle(desired_yaw, behind, _weight(settings.auto_align_strength, delta))
	_previous_target = target
	_initialized = true
	_yaw = lerp_angle(_yaw, desired_yaw, _weight(settings.orbit_smoothing, delta))
	_pitch = lerpf(_pitch, desired_pitch, _weight(settings.orbit_smoothing, delta))
	_zoom = lerpf(_zoom, desired_distance, _weight(settings.zoom_smoothing, delta))
	var boom := Vector3(sin(_yaw) * cos(deg_to_rad(_pitch)), sin(deg_to_rad(_pitch)), cos(_yaw) * cos(deg_to_rad(_pitch)))
	var eye: Vector3 = target + Vector3.UP * settings.pivot_height
	var wanted_pivot: Vector3 = eye - Vector3(sin(_yaw), 0, cos(_yaw)) * settings.forward_offset
	var followed: Vector3 = wanted_pivot if snap else _pivot.lerp(wanted_pivot, _weight(settings.position_smoothing, delta))
	# Follow lag/framing offset cannot push the pivot through nearby scenery.
	_pivot = eye + _safe_motion(eye, followed - eye)
	var safe_distance: float = _safe_motion(_pivot, boom * _zoom).length()
	# Retract immediately for safety; ease only the return to the requested zoom.
	resolved_distance = safe_distance if snap or safe_distance < resolved_distance else lerpf(resolved_distance, safe_distance, _weight(settings.collision_return_smoothing, delta))
	var candidate: Vector3 = _pivot + boom * resolved_distance
	# A corner can block eye-to-camera even when the offset pivot's boom is clear.
	# Drop the small framing offset there, preserving a direct clear player sightline.
	var sight_motion: Vector3 = candidate - eye
	if _safe_motion(eye, sight_motion).length() + 0.001 < sight_motion.length():
		_pivot = eye
		resolved_distance = minf(resolved_distance, _safe_motion(eye, boom * resolved_distance).length())
	camera.global_position = _pivot + boom * resolved_distance
	camera.look_at(camera.global_position - boom, Vector3.UP)
