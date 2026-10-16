extends MobSystem
## Test-only actor factory and timed paths. Production MobSystem code is the baseline.
const BENCH_MOB := preload("res://tests/fixtures/bench_mob_actor.gd")
var no_slide := false
var ai_period_ms := 0
var last_decision: Dictionary[int, int] = {}
var total_tick_us := 0
var decision_us := 0
var decision_calls := 0

func spawn_mob(definition: MobDefinition, position: Vector3, pack: MobPackRuntime) -> MobActor3D:
	# Matches MobSystem.spawn_mob setup; fixture-specific factory is intentionally explicit.
	if not MobDefinitions.is_registered(definition) or not definition.valid(): return null
	_next_mob_id += 1
	var dog := BENCH_MOB.new()
	dog.name = "Mob_%d" % _next_mob_id
	dog.definition = definition
	dog.reaction_profile = definition.reaction_profile
	dog.mob_key = definition.mob_key
	dog.max_hp = definition.max_hp
	dog.attack_damage = definition.attack_damage
	dog.move_speed = definition.move_speed
	dog.visual_id = definition.visual_id
	dog.proximity_aggro = definition.proximity_aggro
	dog.title = definition.display_name
	dog.pack_instance_id = pack.pack_instance_id
	dog.source_metinstone_id = pack.source_metinstone_id
	dog.respawn_enabled = pack.respawn_enabled
	dog.expires_at = pack.expires_at
	dog.setup_mob(_next_mob_id, position)
	dog.home = pack.anchor
	dog.wander_at_ms = Time.get_ticks_msec() + pack.rng.randi_range(1000, 4000)
	dog.no_slide = no_slide
	_world.add_child(dog)
	mobs[dog.mob_instance_id] = dog
	pack.actor_ids.append(dog.mob_instance_id)
	return dog

func tick(delta: float, now: int) -> void:
	var started := Time.get_ticks_usec()
	super.tick(delta, now)
	total_tick_us += Time.get_ticks_usec() - started

func tick_mob(dog: MobActor3D, delta: float, now: int) -> void:
	if ai_period_ms > 0 and last_decision.has(dog.mob_instance_id) and now - last_decision[dog.mob_instance_id] < ai_period_ms:
		# Keep physical movement at 60 Hz, only repeat the last movement
		# direction instead of re-evaluating the chase/return state.
		# This is a behavior-changing experiment, not a gameplay fix.
		var previous := Vector2(dog.velocity.x, dog.velocity.z)
		dog.simulate_mob(delta, previous.normalized() if previous.length_squared() > 0.0001 else Vector2.ZERO, now)
		return
	last_decision[dog.mob_instance_id] = now
	var started := Time.get_ticks_usec()
	super.tick_mob(dog, delta, now)
	decision_us += Time.get_ticks_usec() - started
	decision_calls += 1

func reset_metrics() -> void:
	total_tick_us = 0
	decision_us = 0
	decision_calls = 0
	last_decision.clear()
