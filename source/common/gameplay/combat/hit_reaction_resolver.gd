class_name HitReactionResolver
extends RefCounted
## World resolves this once per accepted hit; clips never decide combat state.
static func resolve(hit: AttackHitDefinition, profile: HitReactionProfile, attack: int, hp: int, locked: bool) -> CombatHitResult:
	var result := CombatHitResult.new()
	result.damage = clampi(int(attack * hit.damage_multiplier),0,hp)
	if result.damage == 0 or result.damage == hp: return result # Death wins over reactions.
	result.reaction = hit.reaction
	match hit.reaction:
		HitReaction.Type.FLINCH:
			if not profile.allow_flinch: result.reaction = HitReaction.Type.NONE
		HitReaction.Type.KNOCKBACK:
			if not profile.allow_knockback: result.reaction = _fallback(profile)
			else: result.knockback_distance = hit.knockback_distance * profile.knockback_scale
		HitReaction.Type.KNOCKDOWN:
			if not profile.allow_knockdown or locked: result.reaction = _fallback(profile)
	result.duration = hit.reaction_duration if result.reaction != HitReaction.Type.NONE else 0.0
	if result.reaction == HitReaction.Type.KNOCKDOWN:
		if profile.allow_knockback: result.knockback_distance = maxf(0.0,hit.knockback_distance * profile.knockback_scale)
		result.get_up_duration = hit.get_up_duration
		result.interrupts_attack = true
	# A dedicated interrupt is independent of knockdown resistance. Flinch never interrupts.
	elif hit.reaction != HitReaction.Type.FLINCH and hit.interrupt_attack and not profile.immune_to_interrupt:
		result.interrupts_attack = true
	return result

static func _fallback(profile: HitReactionProfile) -> HitReaction.Type:
	return HitReaction.Type.FLINCH if profile.allow_flinch else HitReaction.Type.NONE
