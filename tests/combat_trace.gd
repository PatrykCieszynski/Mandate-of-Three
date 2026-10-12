extends Node3D
func _ready() -> void:
	var trace := CombatTraceDefinition.new()
	for i: int in 3:
		var sample := CombatTraceSample.new()
		sample.time_ms = 100+i*50
		sample.base = Vector3(-1+i,0.6,-0.6)
		sample.tip = Vector3(-1+i,0.6,-2)
		trace.samples.append(sample)
	assert(trace.valid(100,200))
	trace.vertical_padding_down = -1
	assert(not trace.valid(100,200))
	trace.vertical_padding_down = 0.9
	trace.vertical_padding_up = NAN
	assert(not trace.valid(100,200))
	trace.vertical_padding_up = 0.3
	assert(CombatTraceResolver.hits_capsule(trace,Transform3D.IDENTITY,Vector3(0,0,-1.4),.4,.8))
	assert(not CombatTraceResolver.hits_capsule(trace,Transform3D.IDENTITY,Vector3(4,0,-1.4),.4,.8))
	assert(not CombatTraceResolver.hits_capsule(trace,Transform3D.IDENTITY,Vector3(0,0,1.4),.4,.8))
	assert(not CombatTraceResolver.hits_capsule(trace,Transform3D.IDENTITY,Vector3(0,4,-1.4),.4,.8))
	# Between two blades, far from all four boundary segments: swept interior must hit.
	assert(CombatTraceResolver.hits_capsule(trace,Transform3D.IDENTITY,Vector3(.5,0,-1.3),.1,1))
	var placed := Transform3D(Basis(Vector3.UP,1.1),Vector3(21,4,-8))
	assert(CombatTraceResolver.hits_capsule(trace,placed,placed*Vector3(.5,0,-1.3),.1,1))
	for combo: BasicAttackComboDefinition in [BasicAttackCombos.BASE,BasicAttackCombos.COMBO_5,BasicAttackCombos.COMBO_6]:
		assert(combo.valid())
		for step: BasicAttackStepDefinition in combo.steps:
			assert(step.combat_trace != null and step.combat_trace.valid(step.hit_start_ms,step.hit_end_ms))
	# High literal blade misses a low capsule without forgiveness, then hits with
	# the shared defaults. Horizontal and large height differences remain misses.
	var high := trace.duplicate(true) as CombatTraceDefinition
	for sample: CombatTraceSample in high.samples:
		sample.base.y = 1.6
		sample.tip.y = 1.6
	high.vertical_padding_down = 0
	high.vertical_padding_up = 0
	assert(not CombatTraceResolver.hits_capsule(high,Transform3D.IDENTITY,Vector3(0,0,-1.4),.4,.8))
	assert(CombatTraceResolver.hits_capsule(high,Transform3D.IDENTITY,Vector3(0,0,-1.4),.35,1.8))
	high.vertical_padding_down = trace.vertical_padding_down
	high.vertical_padding_up = trace.vertical_padding_up
	assert(CombatTraceResolver.hits_capsule(high,Transform3D.IDENTITY,Vector3(0,0,-1.4),.4,.8))
	assert(CombatTraceResolver.hits_capsule(high,Transform3D.IDENTITY,Vector3(0,-.2,-1.4),.4,.8))
	assert(CombatTraceResolver.hits_capsule(high,Transform3D.IDENTITY,Vector3(0,0,-1.4),.35,1.8))
	for miss: Vector3 in [Vector3(4,0,-1.4),Vector3(0,0,1.4),Vector3(0,0,-5),Vector3(0,-4,-1.4),Vector3(0,3,-1.4)]:
		assert(not CombatTraceResolver.hits_capsule(high,Transform3D.IDENTITY,miss,.4,.8))
	assert(CombatTraceResolver.hits_capsule(high,Transform3D.IDENTITY,Vector3(0,-2,-1.4),.4,.8,2.0))
	# No borrowing a low Y interval from an unrelated, distant part of the sweep.
	var disjoint := high.duplicate(true) as CombatTraceDefinition
	disjoint.samples[0].base = Vector3(20,0,-.6)
	disjoint.samples[0].tip = Vector3(20,0,-2)
	disjoint.samples[1].base = Vector3(20,5,-.6)
	disjoint.samples[1].tip = Vector3(20,5,-2)
	disjoint.samples[2].base = Vector3(0,5,-.6)
	disjoint.samples[2].tip = Vector3(0,5,-2)
	assert(not CombatTraceResolver.hits_capsule(disjoint,Transform3D.IDENTITY,Vector3(0,0,-1.4),.4,.8))
	var dog := MobActor3D.new()
	dog.setup_mob(1,Vector3.ZERO)
	var capsule_shape := dog.combat_collider.shape as CapsuleShape3D
	assert(dog.combat_radius() == capsule_shape.radius and dog.combat_height() == capsule_shape.height)
	dog.combat_collider.position.y += .25
	assert(is_equal_approx(dog.combat_bottom_offset(),.25))
	dog.free()
	var no_padding := high.duplicate(true) as CombatTraceDefinition
	no_padding.vertical_padding_down = 0
	no_padding.vertical_padding_up = 0
	assert(is_equal_approx(high.bounds().size.x,no_padding.bounds().size.x) and is_equal_approx(high.bounds().size.z,no_padding.bounds().size.z))
	# Real broadphase, 100 overlapping candidates, with one duplicated body shape.
	for i: int in 100:
		var target := StaticBody3D.new()
		target.collision_layer = 4
		target.position = Vector3((i%10-5)*.08,0,-1.4+(i/10)*.02)
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = .4
		capsule.height = .8
		shape.shape = capsule
		shape.position.y = .4
		target.add_child(shape)
		if i == 0: target.add_child(shape.duplicate())
		add_child(target)
	await get_tree().physics_frame
	var started := Time.get_ticks_usec()
	var candidates := CombatTraceResolver.candidates(get_world_3d().direct_space_state,high,Transform3D.IDENTITY)
	assert(CombatTraceResolver.candidates(get_world_3d().direct_space_state,no_padding,Transform3D.IDENTITY).is_empty(),"High literal blade must not reach low colliders in broadphase without Y padding")
	var unique := {}
	for candidate: Dictionary in candidates:
		if CombatTraceResolver.hits_capsule(high,Transform3D.IDENTITY,candidate.collider.position,.4,.8): unique[candidate.collider.get_instance_id()] = true
	assert(unique.size() == 100,"Broadphase must not silently truncate at 64")
	print("COMBAT_TRACE_OK candidates=",candidates.size()," unique_hits=",unique.size()," usec=",Time.get_ticks_usec()-started)
	get_tree().quit()
