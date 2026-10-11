class_name BasicAttackComboState
extends RefCounted
## Server-owned options; reset the chain without canceling an accepted swing.
var current_combo_step: int = -1
var last_swing_ms: int = -10000
var combo_enabled: bool = false
var combo_skill_level: int = 0
var weapon_mode: StringName = &"onehand_sword"
var _combo_key: StringName
func reset() -> void:
	current_combo_step = -1
	last_swing_ms = -10000
func definition() -> BasicAttackComboDefinition:
	return BasicAttackCombos.resolve(weapon_mode,combo_enabled,combo_skill_level)
func set_enabled(enabled: bool) -> bool:
	if enabled and combo_skill_level == 0: return false
	if enabled != combo_enabled:
		combo_enabled = enabled
		reset()
	return true
func set_skill_level(level: int) -> bool:
	if level < 0 or level > 2: return false
	if level != combo_skill_level:
		combo_skill_level = level
		if level == 0: combo_enabled = false
		reset()
	return true
func set_weapon_mode(mode: StringName) -> bool:
	# Only the current playable weapon has authored gameplay definitions.
	if BasicAttackCombos.resolve(mode,false,0) == null: return false
	if mode != weapon_mode:
		weapon_mode = mode
		reset()
	return true
func take_step(now: int) -> Dictionary:
	var combo := definition()
	if combo == null: return {}
	if _combo_key != combo.combo_key or now-last_swing_ms > combo.reset_ms: reset()
	_combo_key = combo.combo_key
	current_combo_step = (current_combo_step + 1) % combo.steps.size()
	last_swing_ms = now
	# A private copy freezes every timing/damage/reaction field for pending impact.
	var step := combo.steps[current_combo_step].duplicate() as BasicAttackStepDefinition
	return {"combo_key":combo.combo_key,"step_index":current_combo_step,"animation_key":step.animation_key,
		"step":step,"finisher":current_combo_step == combo.steps.size()-1}
