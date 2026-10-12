class_name PlayerCombatRuntime
extends RefCounted
## Server attack state only. The endpoint/service owns orchestration and time.
var sequence: int = -1
var next_attack_ms: int = 0
var movement_unlock_ms: int = 0
var combo := BasicAttackComboState.new()
# Wire presentation retains the last accepted step even after inactivity reset.
var display_combo_step: int = 0
var active_action: Dictionary = {}
var pending_impact: Dictionary = {}
var queued_sequence: int = -1
var desired_facing: Dictionary = {}
# Preserve simultaneous processing order from the former pending/active maps.
var pending_order: int = 0
var active_order: int = 0

func clear_intents() -> void:
	movement_unlock_ms = 0
	pending_impact = {}
	active_action = {}
	queued_sequence = -1
	desired_facing = {}
