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
	print("METIN_ENCOUNTER_OK: thresholds, overkill contribution, once-only reward and fresh respawn lifecycle")
	get_tree().quit()
