class_name CombatFeedback3D
extends Node3D
## Confirmed semantic hits only. Bounded pools, client-only, no HP/state writes.
const MAX_NUMBERS := 64
const MAX_SPARKS := 96
var numbers: Array[Dictionary] = []
var sparks: Array[Dictionary] = []
var number_pool: Array[Label3D] = []
var spark_pool: Array[MeshInstance3D] = []
var seen: Dictionary[String, bool] = {}
var seen_order: Array[String] = []
var number_events := 0
var spark_events := 0
@export var hit_sound: AudioStream
var _audio: AudioStreamPlayer3D
var _spark_mesh: ImmediateMesh
var _spark_material: StandardMaterial3D
var _last_sound_ms := -1000
func _ready() -> void:
	_spark_mesh = ImmediateMesh.new()
	_spark_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for axis: Vector3 in [Vector3.RIGHT,Vector3.UP,Vector3.FORWARD,Vector3(1,1,0).normalized(),Vector3(0,1,1).normalized()]:
		_spark_mesh.surface_add_vertex(-axis)
		_spark_mesh.surface_add_vertex(axis)
	_spark_mesh.surface_end()
	_spark_material = StandardMaterial3D.new()
	_spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_spark_material.albedo_color = Color(1,.85,.4)
	_spark_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_audio = AudioStreamPlayer3D.new()
	_audio.volume_db = -20
	_audio.max_distance = 20
	if hit_sound == null: hit_sound = _placeholder_sound()
	_audio.stream = hit_sound
	add_child(_audio)
func confirm(event: Dictionary, target: Node3D, outgoing: bool) -> bool:
	if int(event.get("damage",0)) <= 0: return false
	var key := "%s:%s:%s:%s" % [event.attacker,event.action_id,event.get("target_kind","mob"),event.get("target_id",event.get("id",0))]
	if seen.has(key): return false
	seen[key] = true
	seen_order.append(key)
	if seen_order.size() > 512: seen.erase(seen_order.pop_front())
	var height: float = target.combat_height() if target.has_method("combat_height") else .8
	var bottom: float = target.combat_bottom_offset() if target.has_method("combat_bottom_offset") else 0.0
	var contact := target.global_position+Vector3.UP*(bottom+height*.65)
	if sparks.size() < MAX_SPARKS:
		var spark: MeshInstance3D
		if spark_pool.is_empty():
			spark = MeshInstance3D.new()
			spark.mesh = _spark_mesh
			spark.material_override = _spark_material
			spark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(spark)
		else: spark = spark_pool.pop_back()
		spark.visible = true
		spark.transparency = 0
		spark.global_position = contact
		spark.scale = Vector3.ONE*.10
		sparks.append({"node":spark,"age":0.0})
		spark_events += 1
	if outgoing and numbers.size() < MAX_NUMBERS:
		var label: Label3D
		if number_pool.is_empty():
			label = Label3D.new()
			label.font_size = 26
			label.pixel_size = .006
			label.outline_size = 4
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			add_child(label)
		else: label = number_pool.pop_back()
		label.visible = true
		label.text = str(event.damage)
		label.modulate = Color("ffd880") if int(event.get("reaction",0)) == HitReaction.Type.KNOCKDOWN else Color.WHITE
		label.global_position = target.global_position+Vector3(randf_range(-.15,.15),bottom+height+.12,randf_range(-.10,.10))
		numbers.append({"node":label,"age":0.0})
		number_events += 1
	if Time.get_ticks_msec()-_last_sound_ms > 60:
		_last_sound_ms = Time.get_ticks_msec()
		_audio.global_position = contact
		_audio.pitch_scale = randf_range(.93,1.07)
		_audio.play()
	return true
func _process(delta: float) -> void:
	for i: int in range(numbers.size()-1,-1,-1):
		var entry: Dictionary = numbers[i]
		entry.age += delta
		entry.node.position.y += delta*.5
		entry.node.modulate.a = clampf((.85-float(entry.age))/.35,0,1)
		if float(entry.age) >= .85:
			entry.node.visible = false
			number_pool.append(entry.node)
			numbers.remove_at(i)
	for i: int in range(sparks.size()-1,-1,-1):
		var entry: Dictionary = sparks[i]
		entry.age += delta
		entry.node.scale = Vector3.ONE*(.1+float(entry.age)*.8)
		entry.node.transparency = clampf(float(entry.age)/.18,0,1)
		if float(entry.age) >= .18:
			entry.node.visible = false
			spark_pool.append(entry.node)
			sparks.remove_at(i)
static func _placeholder_sound() -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(2205*2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i: int in 2205:
		var value := int((sin(i*TAU*1800/22050.0)*.35+rng.randf_range(-.6,.6))*exp(-i/260.0)*10000)
		data.encode_s16(i*2,value)
	var sound := AudioStreamWAV.new()
	sound.format = AudioStreamWAV.FORMAT_16_BITS
	sound.mix_rate = 22050
	sound.data = data
	return sound
