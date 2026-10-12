extends Node3D
## Opt-in native review: real movement bodies, approximate scheduled preview hits.
var hero := SpikePlayer3D.new()
var dog := SpikeMob3D.new()
var age := 0.0
var step_index := 0
var impacted := false
var rest := 0.0
var single := false
var label := Label.new()
var captured := false
var finishing_capture := false

func _ready() -> void:
	hero.setup("Warrior",Color.WHITE)
	add_child(hero)
	hero.set_weapon("iron_sword")
	dog.definition = MobDefinitions.resolve(&"wild_dog")
	dog.setup_mob(1,Vector3(0,0,-1))
	add_child(dog)
	volume(dog,dog.combat_collider,Color(0,1,1,.22))
	volume(dog,dog.movement_collider,Color(1,.65,0,.15))
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1 | 16
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(12,.2,12)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position.y = -.1
	add_child(floor_body)
	var plane := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(12,12)
	plane.mesh = mesh
	add_child(plane)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45,-30,0)
	add_child(light)
	var camera := Camera3D.new()
	camera.position = Vector3(3,2.5,3)
	add_child(camera)
	camera.look_at(Vector3(0,.6,-1))
	label.position = Vector2(15,15)
	add_child(label)
	start_step()

func volume(parent: Node3D, collider: CollisionShape3D, color: Color) -> void:
	var view := MeshInstance3D.new()
	var shape := collider.shape as CapsuleShape3D
	var mesh := CapsuleMesh.new()
	mesh.radius = shape.radius
	mesh.height = shape.height
	view.mesh = mesh
	view.position = collider.position
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	view.material_override = material
	parent.add_child(view)

func start_step() -> void:
	age = 0
	impacted = false
	var step := BasicAttackCombos.BASE.steps[step_index]
	hero.start_attack_advance(0,step.advance_distance,step.motion_duration_ms/1000.0)
	hero.play_swing(step.animation_key,step.motion_duration_ms,step_index==3)

func _physics_process(delta: float) -> void:
	if finishing_capture: return
	if rest > 0:
		rest -= delta
		if rest <= 0:
			hero.position = Vector3.ZERO
			hero.velocity = Vector3.ZERO
			dog.position = Vector3(0,0,-1)
			dog.velocity = Vector3.ZERO
			dog.knockback_velocity = Vector3.ZERO
			dog.hit_reaction.clear()
			step_index = 0
			start_step()
		return
	age += delta
	if not captured and age > .15 and OS.get_cmdline_user_args().has("--body-capture"):
		captured = true
		capture("warrior-body-volumes")
	var step := BasicAttackCombos.BASE.steps[step_index]
	hero.simulate(delta,Vector2.ZERO)
	dog.simulate_mob(delta,Vector2.ZERO,Time.get_ticks_msec())
	if not impacted and age >= step.impact_ms/1000.0:
		impacted = true
		if CombatTraceResolver.hits_capsule(step.combat_trace,hero.transform,dog.position,dog.combat_radius(),dog.combat_height(),dog.combat_bottom_offset()):
			var result := HitReactionResolver.resolve(step,dog.reaction_profile,1,120,false)
			dog.hit_reaction.apply(result,Time.get_ticks_msec())
			dog.apply_knockback(dog.position-hero.position,result.knockback_distance)
			dog.present_hit_lock(int(result.duration*1000),int(result.get_up_duration*1000))
	var end := step.motion_duration_ms if single or step_index==3 else step.direct_input_ms
	label.text = "BODY collision preview | cyan = defending r0.4 | amber = BODY r0.6\nS single/chain | step %d | hero Z %.3f | dog Z %.3f | Esc close" % [step_index+1,hero.position.z,dog.position.z]
	if age*1000 >= end:
		if single or step_index==3:
			if OS.get_cmdline_user_args().has("--body-capture"):
				finishing_capture = true
				await capture("warrior-body-final")
				print("WARRIOR_BODY_RENDER_OK hero=",hero.position," dog=",dog.position)
				get_tree().quit()
			rest = 1.5
		else:
			step_index += 1
			start_step()

func capture(stem: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://.godot/verification/"+stem+".png")

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_S: single = not single
	if event.keycode == KEY_ESCAPE: get_tree().quit()
