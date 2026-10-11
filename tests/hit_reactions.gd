extends Node
## Durable domain contracts: no pixels, clip timing, balance or network fixtures.
func _ready() -> void:
	var normal := HitReactionProfiles.NORMAL
	var finisher := BasicAttackHits.stage(BasicAttackHits.COMBO.size())
	var state := HitReactionState.new()
	for hit: AttackHitDefinition in BasicAttackHits.COMBO.slice(0,3):
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
