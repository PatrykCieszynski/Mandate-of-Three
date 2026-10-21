extends Node3D
## W4a movement/contact contracts; actual damage/replication uses existing network suites.
class TransformedHeightfield extends Node3D:
	var data
func box(at: Vector3, size: Vector3, layer: int) -> void:
	var body:=StaticBody3D.new();body.position=at;body.collision_layer=layer
	var shape:=CollisionShape3D.new();var geometry:=BoxShape3D.new();geometry.size=size
	shape.shape=geometry;body.add_child(shape);add_child(body)

func dog(light: bool, at: Vector3) -> MobActor3D:
	var body:=MobActor3D.new()
	body.definition=MobDefinitions.WILD_DOG;body.setup_mob(1,at)
	assert(body.lightweight_movement==("--dev-light-mob-movement" in (OS.get_cmdline_args()+OS.get_cmdline_user_args())),"server flag owns initial policy")
	body.lightweight_movement=light;add_child(body)
	return body

func step(body: MobActor3D, direction: Vector2, count: int) -> void:
	for i: int in count:
		await get_tree().physics_frame
		body.simulate_mob(1.0/60,direction,Time.get_ticks_msec())

func _ready() -> void:
	Engine.max_fps=60
	get_tree().create_timer(30).timeout.connect(func()->void:get_tree().quit(1))
	box(Vector3(0,-.5,0),Vector3(12,1,12),17)
	box(Vector3(0,1,0),Vector3(.2,2,4),1)
	box(Vector3(2,1,0),Vector3(.2,2,4),1)
	await get_tree().physics_frame
	for light: bool in [false,true]:
		var body:=dog(light,Vector3(-2,.1,0))
		await step(body,Vector2.RIGHT,60)
		assert(body.position.x>.6 and absf(body.position.y)<.1,"ordinary chase ignores scenery, keeps feet on floor")
		await get_tree().physics_frame
		var trace:=CombatTraceDefinition.new()
		for t: int in [100,200]:
			var sample:=CombatTraceSample.new();sample.time_ms=t
			sample.base=Vector3(-1,.6,-1.4);sample.tip=Vector3(1,.6,-1.4);trace.samples.append(sample)
		var attacker:=Transform3D(Basis.IDENTITY,body.position+Vector3(0,0,1.4))
		var found:=false
		for hit: Dictionary in CombatTraceResolver.candidates(get_world_3d().direct_space_state,trace,attacker):
			if hit.collider==body: found=true
		assert(found and CombatTraceResolver.hits_capsule(trace,attacker,body.position,body.combat_radius(),body.combat_height(),body.combat_bottom_offset()),"moving mob retains broadphase BODY and defending hitbox")
		var now:=Time.get_ticks_msec()
		var reaction:=HitReactionResolver.resolve(BasicAttackCombos.BASE.steps.back(),HitReactionProfiles.NORMAL,1,body.hp,false)
		body.hit_reaction.apply(reaction,now);body.apply_knockback(Vector3.RIGHT,reaction.knockback_distance)
		var start:=body.position
		await step(body,Vector2.LEFT,20)
		var wall_limit: float=2-.1-(body.movement_collider.shape as CapsuleShape3D).radius+.03
		assert(body.position.x>start.x+.1 and body.position.x<wall_limit,"finisher displacement keeps native wall collision despite opposite AI intention")
		body.die(Time.get_ticks_msec());var corpse:=body.position
		var system:=MobSystem.new();system.tick_mob(body,1.0/60,Time.get_ticks_msec())
		assert(body.position==corpse and body.collision_layer==0,"death disables blocking and simulation")
		body.queue_free();await get_tree().physics_frame
	# Missing support must fall with native gravity, never hover at the last Y.
	var edge:=dog(true,Vector3(5.98,.002,5))
	await step(edge,Vector2.RIGHT,40)
	assert(edge.position.y<-.05 and edge.position.is_finite() and edge.light_native_ticks>0,"unsupported ground uses native gravity")
	edge.queue_free()
	if "--with-terrain" in OS.get_cmdline_args(): await terrain()
	print("MOB_MOVEMENT_OK: native/light floor, scenery policy, hitboxes, knockback, death, edge", " + Terrain3D" if "--with-terrain" in OS.get_cmdline_args() else "")
	get_tree().quit()

func terrain() -> void:
	var saved: Node3D=load("res://source/common/gameplay/maps/terrain3d_spike/terrain_spike.tscn").instantiate()
	# Load the saved data/native collider, excluding preview authoring code/actors.
	# Never save, sculpt, rebake or alter the map author's checkout/data.
	saved.set_script(null)
	NavigationServer3D.map_set_cell_size(get_world_3d().navigation_map,.125)
	NavigationServer3D.map_set_cell_height(get_world_3d().navigation_map,.1)
	add_child(saved)
	var heightfield=saved.get_node("Navigation/Terrain")
	heightfield.collision.mode=3;heightfield.collision.layer=17;heightfield.collision.mask=0
	heightfield.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var height_source:=preload("res://source/common/gameplay/mobs/mob_terrain_grounding_3d.gd").new(heightfield)
	for policy: String in ["native","ray","height"]:
		for origin: Vector3 in [Vector3(13,0,14),Vector3(15,0,30),Vector3(24,0,30)]:
			origin.y=heightfield.data.get_height(origin)+.1
			assert(origin.is_finite())
			var body:=dog(policy!="native",origin)
			if policy=="height": body.grounding=height_source
			await step(body,Vector2.RIGHT,60)
			print("W4A_TERRAIN policy=",policy," ",origin," -> ",body.position," fast=",body.light_grounded_ticks," native=",body.light_native_ticks)
			assert(body.position.x>origin.x+1,"flat/uphill/downhill traverse saved Terrain3D")
			assert(absf(body.position.y-heightfield.data.get_height(body.position))<.15,"feet match actual saved heightfield")
			body.queue_free();await get_tree().physics_frame
	# API takes global coordinates even when the actor's parent is translated.
	var translated:=Node3D.new();translated.position.x=10;add_child(translated)
	var global_start:=Vector3(13,heightfield.data.get_height(Vector3(13,0,14))+.1,14)
	var shifted:=dog(true,global_start);shifted.grounding=height_source;shifted.reparent(translated,true)
	await step(shifted,Vector2.RIGHT,20)
	assert(absf(shifted.global_position.y-heightfield.data.get_height(shifted.global_position))<.05,"height API uses global actor position")
	translated.queue_free()
	# Mixed surface chooses ray grounding: a low bridge must not snap to terrain.
	var bridge_top: float=heightfield.data.get_height(Vector3(13,0,14))+.5
	box(Vector3(14,bridge_top-.1,14),Vector3(4,.2,4),17)
	var bridge_dog:=dog(true,Vector3(13,bridge_top+.1,14))
	await step(bridge_dog,Vector2.RIGHT,30)
	assert(absf(bridge_dog.position.y-bridge_top)<.05,"ray mode keeps the actual bridge surface")
	bridge_dog.queue_free()
	saved.queue_free()
	await get_tree().physics_frame
	# Mutate ONLY a fresh disposable heightfield, never the authored saved data.
	var fresh:=preload("res://tests/support/world_bench_terrain.gd").add_to(self)
	var source:=preload("res://source/common/gameplay/mobs/mob_terrain_grounding_3d.gd").new(fresh)
	var probe:=dog(true,Vector3(3,.1,3))
	assert(source.resolve(probe,Vector3(4,0,4)).position.y<.01)
	assert(source.resolve(probe,Vector3(9999,0,0)).is_empty(),"missing region has no invented Y")
	fresh.get("data").set_control_hole(Vector3(4,0,4),true)
	assert(source.resolve(probe,Vector3(4,0,4)).is_empty(),"hole refuses height sampling")
	fresh.get("data").set_control_hole(Vector3(4,0,4),false)
	fresh.get("data").set_height(Vector3(4,0,4),100)
	assert(source.resolve(probe,Vector3(4,0,4)).is_empty(),"no teleport up a cliff")
	fresh.get("data").set_height(Vector3(4,0,4),-100)
	assert(source.resolve(probe,Vector3(4,0,4)).is_empty(),"no teleport down a cliff")
	# The addon resets its own transform; test our rejection without reparenting
	# native Terrain3D (which would reinitialize its unsaved data_directory).
	var shifted_terrain:=TransformedHeightfield.new()
	shifted_terrain.data=fresh.get("data");shifted_terrain.position.x=10;add_child(shifted_terrain)
	var unsupported:=preload("res://source/common/gameplay/mobs/mob_terrain_grounding_3d.gd").new(shifted_terrain)
	assert(unsupported.resolve(probe,Vector3(5,0,5)).is_empty(),"unsupported transformed terrain fails to native handling")
	probe.queue_free();shifted_terrain.queue_free();fresh.queue_free()
