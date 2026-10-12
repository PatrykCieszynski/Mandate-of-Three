@tool
class_name WorldVisualEnvironment
extends Sky3D
## Server calendar -> Sky3D celestial math -> continuous solar-elevation lighting.
@export var sun_energy_curve: Curve
@export var ambient_energy_curve: Curve
@export var sky_contribution_curve: Curve
@export var exposure_curve: Curve
@export var fog_density_curve: Curve
@export var fog_energy_curve: Curve
@export var atmosphere_tint: Gradient
@export var fog_tint: Gradient
var world_time: WorldTime
var daylight: float = 1.0
var star_visibility: float = 0.0
var moon_phase: float = 0.0

func _ready() -> void:
	# Sky3D's discrete day/night contribution tween must not override our curves.
	if _contrib_tween != null: _contrib_tween.kill()
	if sky.day_night_changed.is_connected(_start_sky_contrib_tween):
		sky.day_night_changed.disconnect(_start_sky_contrib_tween)
	game_time_enabled = false
	editor_time_enabled = false
	tod.system_sync = false
	apply_world_time(float(tod.get_unix_timestamp()))

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		apply_world_time(float(tod.get_unix_timestamp()))
	elif world_time != null and world_time.synchronized:
		apply_world_time(world_time.unix_time())

func apply_world_time(game_unix: float) -> void:
	if not is_finite(game_unix) or game_unix < 0.0: return
	# An editor-created empty node may precede its authored profile resources.
	if [sun_energy_curve,ambient_energy_curve,sky_contribution_curve,exposure_curve,fog_density_curve,fog_energy_curve,atmosphere_tint,fog_tint].has(null): return
	var whole: int = int(floor(game_unix))
	var date: Dictionary = Time.get_datetime_dict_from_unix_time(whole)
	# Date drives moon phases/star rotation; fractional hours keep motion smooth.
	tod.year = date.year
	tod.month = date.month
	tod.day = date.day
	tod.current_time = float(date.hour) + float(date.minute)/60.0 + (float(date.second)+game_unix-whole)/3600.0
	var sun_height: float = cos(sky.sun_altitude)
	daylight = smoothstep(-0.13,0.26,sun_height)
	star_visibility = 1.0-smoothstep(-0.18,0.03,sun_height)
	sky.sun_light_energy = sun_energy_curve.sample_baked(daylight)
	moon_phase = clampf((1.0-sun.position.normalized().dot(moon.position.normalized()))*0.5,0.0,1.0)
	sky.moon_light_energy = 0.65*(1.0-daylight)*moon_phase
	sky.atm_day_tint = atmosphere_tint.sample(daylight)
	sky.atm_night_tint = Color(0.045,0.065,0.12)
	sky.ground_color = Color(0.025,0.035,0.07).lerp(Color(0.36,0.42,0.46),daylight)
	sky.starmap_color = Color(0.5*star_visibility,0.54*star_visibility,0.65*star_visibility,0.85)
	sky.star_field_color = Color(star_visibility,star_visibility,star_visibility)
	sky.clouds_night_color = Color(0.045,0.06,0.1)
	environment.ambient_light_color = Color(0.25,0.33,0.5).lerp(sun.light_color,daylight)
	environment.ambient_light_energy = ambient_energy_curve.sample_baked(daylight)
	environment.ambient_light_sky_contribution = sky_contribution_curve.sample_baked(daylight)
	environment.tonemap_exposure = exposure_curve.sample_baked(daylight)
	environment.fog_density = fog_density_curve.sample_baked(daylight)
	environment.fog_light_color = fog_tint.sample(daylight)
	environment.fog_light_energy = fog_energy_curve.sample_baked(daylight)
