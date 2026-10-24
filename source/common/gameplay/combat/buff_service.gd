class_name BuffService
## Runtime-only timed buffs stored on PlayerResource. World3D derives current stats
## from these sources and expires their projection without a legacy actor/StatusTick.
## This service mutates only the source data and notifies the existing projection.

## Grants [param stat] +[param amount] for [param duration_s] seconds.
## Re-applying the SAME stat+amount refreshes the duration instead of stacking
## (drinking a second tonic extends it, never doubles it).
static func apply(player: PlayerResource, stat: StringName, amount: float, duration_s: float) -> void:
	if player == null or amount == 0.0 or duration_s <= 0.0:
		return
	var expires_ms: int = Time.get_ticks_msec() + int(duration_s * 1000.0)
	for buff: Dictionary in player.active_buffs:
		if buff["stat"] == stat and is_equal_approx(float(buff["amount"]), amount):
			buff["expires_ms"] = maxi(int(buff["expires_ms"]), expires_ms)
			player.combat_stats_changed.emit()
			return
	player.active_buffs.append(
		{"stat": stat, "amount": amount, "expires_ms": expires_ms}
	)

	player.combat_stats_changed.emit()


## Prune expired source records; the derived projection already excludes them.
static func tick(player: PlayerResource) -> void:
	if player == null:
		return
	var buffs: Array = player.active_buffs
	var now: int = Time.get_ticks_msec()
	var changed := false
	for i: int in range(buffs.size() - 1, -1, -1):
		if now >= int(buffs[i]["expires_ms"]):
			buffs.remove_at(i)
			changed=true
	if changed: player.combat_stats_changed.emit()
