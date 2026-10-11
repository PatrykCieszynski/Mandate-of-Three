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
	var candidates := CombatTraceResolver.candidates(get_world_3d().direct_space_state,trace,Transform3D.IDENTITY)
	var unique := {}
	for candidate: Dictionary in candidates:
		if CombatTraceResolver.hits_capsule(trace,Transform3D.IDENTITY,candidate.collider.position,.4,.8): unique[candidate.collider.get_instance_id()] = true
	assert(unique.size() == 100,"Broadphase must not silently truncate at 64")
	print("COMBAT_TRACE_OK candidates=",candidates.size()," unique_hits=",unique.size()," usec=",Time.get_ticks_usec()-started)
	get_tree().quit()
