extends Node3D
## Small lifecycle and real melee integration contracts; no pacing/balance assertions.
func _ready() -> void:
	var definition: MetinDefinition = preload("res://source/common/gameplay/encounters/metin/first_metin.tres").duplicate(true)
	assert(definition.valid())
	var runtime := MetinRuntime.new()
	runtime.definition = definition
	runtime.spawn(0)
	var original_id: String = runtime.stone_instance_id
	assert(runtime.damage(0,definition.max_hp,0).is_empty())
	var first: Dictionary = runtime.damage(11,definition.max_hp/4,100)
	assert(first.waves == [0] and first.reward_owner == 0)
	var next: Dictionary = runtime.damage(22,definition.max_hp/2,200)
	assert(next.waves == [1,2], "Large hit processes each crossed threshold")
	var final: Dictionary = runtime.damage(11,definition.max_hp,300)
	assert(final.waves.is_empty() and final.reward_owner == 11, "Contribution uses actual damage, ties choose stable owner")
	assert(runtime.reward_claimed and runtime.state == "DEAD" and runtime.damage(22,1,301).is_empty(), "Death and reward cannot repeat")
	assert(not runtime.ready_to_respawn(runtime.respawn_at-1) and runtime.ready_to_respawn(runtime.respawn_at))
	runtime.spawn(1)
	assert(runtime.hp == definition.max_hp and runtime.participants.is_empty() and not runtime.reward_claimed and runtime.stone_instance_id != original_id)
	_check_target_identity()
	print("METIN_ENCOUNTER_OK: thresholds, overkill contribution, once-only reward and fresh respawn lifecycle")
	get_tree().quit()

func _check_target_identity() -> void:
	# Detached actors exercise identity/lifecycle without input, pixels or pacing.
	var world := SpikeWorld3D.new()
	var combat := SpikeCombat3D.new()
	world.add_child(combat)
	combat._world = world
	var dog := SpikeWildDog3D.new()
	dog.setup_dog(17,Vector3.ZERO)
	world.add_child(dog)
	combat.dogs[17] = dog
	var mob: Dictionary = {"kind":&"mob","id":17}
	combat.select_target(mob)
	mob.id = 18
	assert(combat.selected_target.id == 17 and combat._resolve_target(combat.selected_target) == dog, "Selection owns its identity")
	dog.die(0)
	combat.assist_direction(Vector2.ZERO)
	assert(combat.selected_target.is_empty() and not combat.autoattack, "Death clears even without autoattack")
	combat.dogs.erase(17)
	dog.free()
	dog = SpikeWildDog3D.new()
	dog.setup_dog(18,Vector3.ZERO)
	world.add_child(dog)
	combat.dogs[18] = dog
	assert(combat.selected_target.is_empty() and combat._resolve_target({"kind":&"mob","id":17}) == null, "Replacement identity never revives old selection")
	combat.select_target({"kind":&"mob","id":18})
	combat.autoattack = true
	dog.ai_state = "DISABLED"
	combat._clear_invalid_target()
	assert(combat.selected_target.is_empty() and not combat.autoattack)
	dog.ai_state = "IDLE"
	combat.select_target({"kind":&"mob","id":18})
	combat.autoattack = true
	combat.dogs.erase(18)
	combat._clear_invalid_target()
	assert(combat.selected_target.is_empty() and not combat.autoattack, "Dynamic removal clears selection")
	combat.dogs[18] = dog
	combat.select_target({"kind":&"mob","id":18})
	combat.autoattack = true
	dog.queue_free()
	combat._clear_invalid_target()
	assert(combat.selected_target.is_empty() and not combat.autoattack, "Queued deletion cannot remain a target")
	combat.dogs.erase(18)
	var encounter := MetinEncounter.new()
	world.add_child(encounter)
	world.metin_encounter = encounter
	encounter.runtime.definition = encounter.definition
	encounter.stone = MetinStone3D.new()
	world.add_child(encounter.stone)
	encounter.runtime.spawn(0)
	var stone_target: Dictionary = {"kind":&"metin","id":encounter.runtime.stone_instance_id}
	combat.select_target(stone_target)
	assert(combat._resolve_target(combat.selected_target) == encounter.stone)
	combat.autoattack = true
	encounter.runtime.damage(1,encounter.definition.max_hp,0)
	combat._clear_invalid_target()
	assert(combat.selected_target.is_empty() and not combat.autoattack, "Metin death clears selection")
	encounter.runtime.spawn(0)
	assert(combat.selected_target.is_empty())
	combat.select_target({"kind":&"metin","id":encounter.runtime.stone_instance_id})
	combat.autoattack = true
	encounter.runtime.spawn(1)
	combat._clear_invalid_target()
	assert(combat.selected_target.is_empty() and not combat.autoattack and combat._resolve_target(stone_target) == null, "New instance/site invalidates an old identity even on the same stone node")
	combat.select_target({"kind":&"metin","id":encounter.runtime.stone_instance_id})
	combat.autoattack = true
	encounter.runtime.state = "COOLDOWN"
	combat._clear_invalid_target()
	assert(combat.selected_target.is_empty() and not combat.autoattack, "Cooldown invalidates selection without requiring a DEAD snapshot")
	assert(combat._resolve_target({}) == null and combat._resolve_target({"kind":&"missing","id":18}) == null)
	world.free()
