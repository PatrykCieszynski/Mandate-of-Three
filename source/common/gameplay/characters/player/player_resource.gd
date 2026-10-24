class_name PlayerResource
extends Resource


const EXP_ATTRIBUTE_MILESTONES: int = 3

## Profile customization limits, shared by the client edit UI and server validator.
const MAX_PROFILE_STATUS_LEN: int = 200
const ALLOWED_PROFILE_ANIMATIONS: PackedStringArray = ["idle", "run", "death"]
## Hard cap on how many achievement chips show on the profile trophy strip.
const MAX_DISPLAYED_TROPHIES: int = 3

const BASE_STATS: Dictionary[StringName, float] = {
	Stat.HEALTH_MAX: 50.0,
	# Low innate attack power on purpose: most of your damage comes from your
	# weapon's AD + the Strength attribute, so leveling and gear both matter and
	# a fresh level-1 is meant to feel weak. AttributeMap adds STR/DEX contributions.
	Stat.AD: 10.0,
	Stat.ARMOR: 15.0,
	Stat.MR: 15.0,
	# Baseline MP pool; active World3D combat projects this through character stats.
	# basic attacks stay free. INT grows the pool and regeneration.
	Stat.MANA_MAX: 50.0,
	Stat.MANA_REGEN: 0.5,
	Stat.MOVE_SPEED: 90.0,
	Stat.ATTACK_SPEED: 100.0
}

## Existing free maximum HP per level, composed by the World3D stat projection.
const HEALTH_PER_LEVEL: float = 5.0

@export var player_id: int
@export var account_name: String

@export var display_name: String = "Player"
@export var skin_id: int = 1 # Default skin

## Opaque persistence compatibility only; never gameplay or economic authority.
@export var retired_profile_fields: Dictionary = {}

@export var attributes: Dictionary[StringName, int]
@export var available_attributes_points: int
@export var available_skill_points: int
@export var exp_thresholds_claimed: int
@export var stats_version: int = 1
@export var stats_revision: int
var stats_migrated: bool = false

@export var level: int = 1
## Character experience toward the next level (resets to the overflow on level-up).
@export var experience: int

@export var server_roles: Dictionary

@export var friends: PackedInt64Array

## Per-player block list. When X has Y in here, the server suppresses every
## chat message Y produces (DM / world / guild / overhead bubbles) from
## reaching X's client. Asymmetric — Y never knows. Mirrors how friends is
## persisted (JSON column on the players row, see world_store_sqlite.gd).
@export var blocked_ids: PackedInt64Array

## Owned cosmetic skin IDs retained by profile persistence; creation skin is owned.
@export var owned_skins: PackedInt64Array

## Legacy statistics payload; also retains general played-time accounting.
@export var lb_stats: Dictionary

## Vanity titles retained in the character profile; display_title selects one.
@export var titles_unlocked: PackedStringArray
## Currently active title (shown on profile under display_name). Empty = no
## title displayed. Auto-set to a newly-granted title only if no title is
## currently active — so players don't lose their chosen banner.
@export var display_title: String
## Map-admission keys. Currently managed by staff through /wardstone.
@export var wardstones: PackedStringArray
## Up to 3 trophies the player pins to their profile's right-side chip strip.
## Each entry must also be in titles_unlocked. Separate from display_title (the
## one shown under their name) — these are the "achievement flex" picks.
@export var displayed_trophies: PackedStringArray

# Profile
@export var profile_status: String = "Hello I'am new!"
@export var profile_animation: String = "idle"

@export var last_position: Vector2 = Vector2.ZERO
@export var current_instance: String

## World3D refreshes derived character stats when the authoritative level changes.
signal level_gained
## Runtime source notification; no persistence or network work in listeners.
signal combat_stats_changed

## Current Network ID
var current_peer_id: int

## Server-side runtime stamp of when the current session began (Time.get_ticks_msec).
## Set on auth, consumed at disconnect to bump lb_stats["played_seconds"]. Not
## persisted — each session starts fresh.
var session_start_ms: int = 0

var stats: Dictionary

## Live timed stat buffs ({stat, amount, expires_ms} — see BuffService). Runtime
## only on purpose: survives instance changes within a session, gone on logout.
var active_buffs: Array[Dictionary] = []

## Per-node gather cooldowns (node_id -> next-ready time in ms). Runtime only, not persisted.
var gather_cooldowns: Dictionary

## Legacy runtime story flags; no active quest runtime or persistence.
var character_flags: Dictionary


func has_character_flag(flag: StringName) -> bool:
	return character_flags.get(flag, false)


func set_character_flag(flag: StringName) -> void:
	character_flags[flag] = true


func init(
	_player_id: int,
	_account_name: String,
	_display_name: String = display_name,
	_skin_id: int = skin_id
) -> void:
	player_id = _player_id
	account_name = _account_name
	display_name = _display_name
	skin_id = _skin_id


func level_up() -> void:
	available_skill_points += 1
	exp_thresholds_claimed = 0
	level += 1
	level_gained.emit()


## Character xp to advance a level: one clean linear-incremental curve — level N
## costs N × this. It's already super-linear, so each level is harder than the
## last (19→20 needs ~19× the first level) and the late game gets meaty on its
## own — no breakpoints or special-casing. Shape the PACING via xp SOURCES (quest
## rewards + mob xp), which is the honest, flexible lever. Total to cap (20) with
## base 70 ≈ 13,300.
const LEVEL_XP_BASE: int = 70


func level_xp_to_next() -> int:
	return LEVEL_XP_BASE * maxi(1, level)


## Milestones use integer arithmetic: ceil(required * quarter / 4).
func attained_exp_thresholds() -> int:
	var count: int = 0
	for quarter: int in range(1,EXP_ATTRIBUTE_MILESTONES+1):
		if experience >= (level_xp_to_next() * quarter + 3) / 4: count += 1
	return count

func progression_state() -> Dictionary:
	return {"version":stats_version,"thresholds":exp_thresholds_claimed,"skill_points":available_skill_points,"revision":stats_revision}

func load_progression_state(value: Dictionary) -> void:
	stats_version = int(value.get("version",0))
	available_skill_points = int(value.get("skill_points",0))
	stats_revision = int(value.get("revision",0))
	if stats_version == 0:
		# Six old meanings cannot be translated safely. Refund ALL spent points.
		for amount: int in attributes.values(): available_attributes_points += maxi(0,amount)
		attributes.clear()
		exp_thresholds_claimed = attained_exp_thresholds()
		stats_version = 1
		stats_migrated = true
	else:
		exp_thresholds_claimed = int(value.get("thresholds",0))

func add_experience(amount: int) -> Dictionary:
	var points_before := available_attributes_points
	var skills_before := available_skill_points
	var levels_gained: int = 0
	while amount > 0:
		var required := level_xp_to_next()
		var accepted := mini(amount, required - experience)
		experience += accepted
		amount -= accepted
		var attained := attained_exp_thresholds()
		available_attributes_points += maxi(0,attained-exp_thresholds_claimed)
		exp_thresholds_claimed = maxi(attained,exp_thresholds_claimed)
		if experience >= required:
			experience -= required
			level_up()
			levels_gained += 1
	return {"level":level,"experience":experience,"levels_gained":levels_gained,"points_gained":available_attributes_points-points_before,"skill_points_gained":available_skill_points-skills_before}
