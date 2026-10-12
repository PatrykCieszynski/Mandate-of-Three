class_name WorldTime
extends RefCounted
## Calendar seconds stay unwrapped: midnight and month changes are continuous.
var synchronized: bool = false
var rate: float = 0.0
var _authority: bool = false
var _unix: float = 0.0
var _target_unix: float = 0.0
var _anchor_ticks: int = 0
var _sequence: int = -1

static func authority(settings: WorldTimeSettings) -> WorldTime:
	var clock := WorldTime.new()
	clock._authority = true
	clock.synchronized = true
	clock.rate = 1440.0 / settings.minutes_per_day
	clock._unix = settings.game_time_at(Time.get_unix_time_from_system())
	clock._anchor_ticks = Time.get_ticks_msec()
	return clock

func unix_time() -> float:
	return _unix + (Time.get_ticks_msec() - _anchor_ticks) * 0.001 * rate if _authority else _unix

func advance(delta: float) -> void:
	if _authority or not synchronized or not is_finite(delta) or delta <= 0.0: return
	var previous: float = _unix
	_unix += delta * rate
	_target_unix += delta * rate
	# Correct drift smoothly; never lerp wrapped 23:59 -> 00:00 backwards.
	_unix = maxf(previous,lerpf(_unix,_target_unix,1.0-exp(-2.0*delta)))

func accept_sample(game_unix: float, game_rate: float, sequence: int) -> bool:
	if _authority or sequence <= _sequence or sequence < 0: return false
	if not is_finite(game_unix) or game_unix < 0 or game_unix > 253402300799.0: return false
	if not is_finite(game_rate) or game_rate < 0 or game_rate > 86400.0: return false
	_sequence = sequence
	_target_unix = game_unix
	rate = game_rate
	if not synchronized:
		_unix = game_unix
		synchronized = true
	return true
