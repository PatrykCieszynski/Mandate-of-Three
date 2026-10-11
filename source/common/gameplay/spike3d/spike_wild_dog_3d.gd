class_name SpikeWildDog3D
extends SpikeCharacter3D
## Visuals resolve independently. AI, hit stun and knockback run only
## on the server; clients interpolate position and play presentation effects.

const MAX_HP: int = 120
var max_hp: int = MAX_HP
var attack_damage: int = 6
var source_metinstone_id: String = ""
var respawn_enabled: bool = true
var expires_at: int = 0
var title: String = "Wild Dog"
var definition: MobDefinition
var mob_key: StringName = &"wild_dog"
var visual_id: StringName = &"stray_dog"
var move_speed: float = 2.8
var mob_instance_id: int
# Existing combat/target consumers use this alias for the runtime identity.
var mob_id: int:
	get: return mob_instance_id
	set(value): mob_instance_id = value
var pack_instance_id: int = 0
var proximity_aggro: bool = true
var return_target: Vector3
var wander_target: Vector3
var wander_at_ms: int = 0
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
var hp_label: Label3D
var _selected := false
var _hp_bar: Sprite3D
var _hp_fill: Sprite3D
static var _bar_texture: Texture2D
var name_label: Label3D
var presentation: DogVisual3D

func setup_dog(id: int, spawn: Vector3) -> void:
	hp = max_hp
	mob_id = id
	home = spawn
	position = spawn
	collision_layer = 4
	collision_mask = 16 # Floor layer only; scenery remains layer 1.
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 0.8
	combat_collider = collision
	collision.shape = shape
	collision.position.y = 0.4
	add_child(collision)
	if not GameMode.is_world_server():
		presentation = DogVisual3D.new()
		presentation.visual_id = visual_id
		add_child(presentation)
		name_label = _label(title,1.20,20)
		hp_label = _label("",.88,16)
		hp_label.visible = false
		if _bar_texture == null:
			var image := Image.create(64,6,false,Image.FORMAT_RGBA8)
			image.fill(Color.WHITE)
			_bar_texture = ImageTexture.create_from_image(image)
		_hp_bar = _bar(Color("18191be0"))
		_hp_fill = _bar(Color("ba4944"))
		_hp_fill.render_priority = 1
		_hp_fill.region_enabled = true

func _label(text: String, height: float, size: int) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position.y = height
	label.font_size = size
	label.pixel_size = 0.006
	label.outline_size = 4
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	add_child(label)
	return label

func move_dog(delta: float, direction: Vector2, now: int) -> void:
	if now < stunned_until_ms or hit_reaction.locked(now) or knockback_active(): direction = Vector2.ZERO
	var displaced := knockback_active()
	var displacement_velocity := damp_knockback(delta)
	velocity.x = direction.x * move_speed + displacement_velocity.x
	velocity.z = direction.y * move_speed + displacement_velocity.z
	velocity.y = -0.5 if is_on_floor() else velocity.y - GRAVITY * delta
	if direction.length_squared() > 0.001: rotation.y = atan2(-direction.x, -direction.y)
	var regular_mask := collision_mask
	if displaced: collision_mask |= 1 # Impulses respect scenery; normal pack AI stays unchanged.
	move_and_slide()
	collision_mask = regular_mask

func die(now: int) -> void:
	ai_state = "DEAD"
	hit_reaction.clear()
	target_peer = 0
	dead_until_ms = now + 6000
	knockback_velocity = Vector3.ZERO
	visible = false
	collision_layer = 0

func present_snapshot(snapshot: Array) -> void:
	var previous_state := ai_state
	hp = snapshot[MobSnapshot.Field.HP]
	ai_state = MobSnapshot.state_name(snapshot[MobSnapshot.Field.STATE])
	var active := ai_state not in ["DEAD", "DISABLED"]
	# The corpse is presentation only. Collision disables immediately as before.
	visible = ai_state != "DISABLED"
	collision_layer = 4 if active else 0
	name_label.visible = active
	hp_label.visible = active and _selected
	_hp_bar.visible = active
	_hp_fill.visible = active
	if ai_state == "DEAD" and previous_state != "DEAD": presentation.play_death()
	elif active and previous_state in ["DEAD", "DISABLED"]: presentation.reset_alive()
	presentation.set_hit_lock(snapshot[MobSnapshot.Field.DOWN_REMAINING]/1000.0,snapshot[MobSnapshot.Field.GET_UP_REMAINING]/1000.0)
	apply_snapshot(snapshot[MobSnapshot.Field.POSITION], snapshot[MobSnapshot.Field.YAW])
	hp_label.text = "%d / %d" % [hp, max_hp]
	_update_hp_bar()

func interpolate(delta: float) -> void:
	var previous_position := position
	super.interpolate(delta)
	var moving := Vector2(position.x - previous_position.x, position.z - previous_position.z).length() > delta * 0.1
	presentation.set_locomotion(ai_state, moving)

func play_hit() -> void:
	presentation.play_hit()

func mark_selected(selected: bool) -> void:
	_selected = selected
	if hp_label != null: hp_label.visible = selected and ai_state not in ["DEAD","DISABLED"]
	if name_label != null: name_label.modulate = Color("ffe291") if selected else Color.WHITE

func present_hit_lock(down_ms: int, get_up_ms: int) -> void:
	if presentation != null: presentation.set_hit_lock(down_ms/1000.0,get_up_ms/1000.0)

func _bar(color: Color) -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.texture = _bar_texture
	sprite.pixel_size = .0075
	sprite.position.y = 1.06
	sprite.modulate = color
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.no_depth_test = true
	add_child(sprite)
	return sprite

func _update_hp_bar() -> void:
	if _hp_fill == null: return
	var fraction := clampf(float(hp)/maxi(1,max_hp),0,1)
	_hp_fill.region_rect = Rect2(0,0,64*maxf(.001,fraction),6)
	# Pixel offset follows the billboard rather than moving along world X.
	_hp_fill.offset.x = -(1-fraction)*32
