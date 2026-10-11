extends Node
## Durable domain contracts: no pixels, clip timing, balance or network fixtures.
func _ready() -> void:
	var expected := [[1,2,3,4],[1,2,3,5,7],[1,2,3,5,6,4]]
	for index: int in BasicAttackCombos.ALL.size():
		var combo := BasicAttackCombos.ALL[index]
		assert(combo.valid() and combo.steps.size() == expected[index].size())
		for i: int in combo.steps.size():
			var step := combo.steps[i]
			assert(step.animation_key == StringName("onehand_sword__combo_%02d" % expected[index][i]))
			assert(step.reaction == (HitReaction.Type.KNOCKDOWN if i == combo.steps.size()-1 else HitReaction.Type.FLINCH))
		var runtime := BasicAttackComboState.new()
		assert(runtime.set_skill_level(index) and runtime.definition() == BasicAttackCombos.BASE)
		if index > 0: assert(runtime.set_enabled(true))
		else: assert(not runtime.set_enabled(true))
		assert(runtime.definition() == combo)
		for i: int in combo.steps.size(): assert(runtime.take_step(100+i*800).step_index == i)
		assert(runtime.take_step(100+combo.steps.size()*800).step_index == 0)
		var frozen := runtime.take_step(200+combo.steps.size()*800)
		if index > 0: runtime.set_enabled(false)
		else: runtime.reset()
		assert(runtime.take_step(300+combo.steps.size()*800).step_index == 0)
		assert(frozen.step_index == 1 and frozen.step.animation_key == combo.steps[1].animation_key)
		assert(frozen.step != combo.steps[1], "Pending step is a private frozen copy")
		assert(runtime.take_step(10000).step_index == 0, "Timeout resets the chain")
		runtime.reset()
		assert(runtime.take_step(10100).step_index == 0, "Action interruption resets the chain")
	var runtime := BasicAttackComboState.new()
	for level: int in [0,1,2]:
		runtime.set_skill_level(level)
		assert(runtime.definition() == BasicAttackCombos.BASE, "OFF always uses four hits")
	assert(not runtime.set_skill_level(3) and not runtime.set_weapon_mode(&"unknown"))
	var character := SpikeCharacter3D.new()
	character.setup("Headless combo contract",Color.WHITE)
	assert(character.player_presentation == null and character.find_children("*","Label3D",true,false).is_empty(), "World does not load optional Warrior presentation")
	character.free()
	var normal := HitReactionProfiles.NORMAL
	var finisher: AttackHitDefinition = BasicAttackCombos.BASE.steps.back()
	var state := HitReactionState.new()
	for hit: AttackHitDefinition in BasicAttackCombos.BASE.steps.slice(0,3):
		var flinch := HitReactionResolver.resolve(hit,normal,10,100,false)
		assert(flinch.reaction == HitReaction.Type.FLINCH and not flinch.interrupts_attack)
		state.apply(flinch,100)
		assert(not state.locked(100), "Flinch must not lock movement or attacks")
	var down := HitReactionResolver.resolve(finisher,normal,1,100,false)
	assert(down.reaction == HitReaction.Type.KNOCKDOWN and down.interrupts_attack)
	state.apply(down,100)
	var deadline := state.get_up_until_ms
	assert(state.locked(100) and state.locked(state.down_until_ms) and not state.locked(deadline))
	var repeat := HitReactionResolver.resolve(finisher,normal,1,100,state.locked(101))
	state.apply(repeat,101)
	assert(repeat.reaction != HitReaction.Type.KNOCKDOWN and state.get_up_until_ms == deadline, "Re-hits cannot extend down/get-up")
	for profile: HitReactionProfile in [HitReactionProfiles.ELITE,HitReactionProfiles.BOSS,HitReactionProfiles.WORLD_BOSS]:
		var immune := HitReactionResolver.resolve(finisher,profile,1,100,false)
		assert(immune.damage > 0 and immune.reaction == HitReaction.Type.FLINCH and not immune.interrupts_attack)
	var dedicated := finisher.duplicate() as AttackHitDefinition
	dedicated.interrupt_attack = true
	assert(HitReactionResolver.resolve(dedicated,HitReactionProfiles.BOSS,1,100,false).interrupts_attack, "Knockdown immunity does not grant interrupt immunity")
	var knockback := AttackHitDefinition.new()
	knockback.reaction = HitReaction.Type.KNOCKBACK
	knockback.knockback_distance = 2
	assert(HitReactionResolver.resolve(knockback,HitReactionProfiles.ELITE,1,100,false).knockback_distance < knockback.knockback_distance)
	assert(not HitReactionResolver.resolve(knockback,normal,1,100,false).interrupts_attack)
	knockback.interrupt_attack = true
	assert(HitReactionResolver.resolve(knockback,normal,1,100,false).interrupts_attack)
	var lethal := HitReactionResolver.resolve(finisher,normal,1000,100,false)
	assert(lethal.damage == 100 and lethal.reaction == HitReaction.Type.NONE)
	var mob := SpikeWildDog3D.new()
	mob.mob_instance_id = 123
	mob.hit_reaction.apply(down,100)
	var snapshot := MobSnapshot.capture(mob,101)
	assert(snapshot[MobSnapshot.Field.DOWN_REMAINING] > 0 and snapshot[MobSnapshot.Field.GET_UP_REMAINING] > 0, "Late join carries remaining down/get-up")
	snapshot = MobSnapshot.capture(mob,state.down_until_ms)
	assert(snapshot[MobSnapshot.Field.DOWN_REMAINING] == 0 and snapshot[MobSnapshot.Field.GET_UP_REMAINING] > 0)
	mob.free()
	print("HIT_REACTIONS_OK: profiles, noninterrupting flinch, authoritative lock, bounded re-hits, interrupt independence and snapshot recovery")
	get_tree().quit()
