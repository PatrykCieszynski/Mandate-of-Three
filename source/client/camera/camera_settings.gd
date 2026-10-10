class_name MandateCameraSettings
extends Resource
## Degrees and world units; presentation only, never part of movement RPCs.
@export_range(1.0, 30.0) var min_distance: float = 4.0
@export_range(1.0, 30.0) var max_distance: float = 12.0
@export var default_distance: float = 8.0
@export_range(-30.0, 80.0) var min_pitch: float = -15.0
@export_range(-30.0, 80.0) var max_pitch: float = 65.0
@export var default_pitch: float = 40.0
@export var default_yaw: float = 0.0
@export var orbit_sensitivity: float = 0.25
@export var zoom_speed: float = 1.0
@export var position_smoothing: float = 12.0
@export var orbit_smoothing: float = 24.0
@export var zoom_smoothing: float = 12.0
@export var collision_return_smoothing: float = 8.0
@export var collision_radius: float = 0.25
@export var collision_margin: float = 0.05
@export_flags_3d_physics var collision_mask: int = 1
@export var pivot_height: float = 1.3
@export var forward_offset: float = 0.6
@export var teleport_distance: float = 5.0
@export var fov: float = 55.0
@export var auto_align_enabled: bool = false
@export var auto_align_delay: float = 3.0
@export var auto_align_strength: float = 0.5
