class_name WorldTimeSettings
extends Resource
## One accelerated calendar shared by world processes with the same UTC epoch.
@export_range(1.0,1440.0,1.0) var minutes_per_day: float = 96.0
@export var real_epoch_unix: int = 1791806400 # 2026-10-12 12:00 UTC
@export var game_epoch_unix: int = 1750519800 # 2025-06-21 15:30

func game_time_at(real_unix: float) -> float:
	return float(game_epoch_unix) + (real_unix - float(real_epoch_unix)) * 1440.0 / minutes_per_day
